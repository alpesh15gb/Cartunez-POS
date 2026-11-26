import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { parse } from "csv-parse/sync";
import { records, getRecord, putRecord } from "../db.js";
import {
  type Actor,
  allow,
  scoped,
  integer,
  text,
  multiline,
  fail,
  id,
  audit,
  fitment,
  normalize,
} from "../domain.js";
import { supersedeBillEconomics } from "../bill-economics.js";
import { buildProduct, CatalogCodes, previewCatalog } from "../catalog.js";
import { queueMagentoSync } from "../online-queue.js";
import { emailAddress, noTax } from "../settings.js";

export function catalogRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("products", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const existing = body.id
      ? await scoped(tx, actor, "product", body.id)
      : undefined;
    // A blank SKU only creates a new item code for a new part; edits keep the existing SKU.
    const input = { ...existing, ...body };
    if (existing && !String(body.sku ?? "").trim()) input.sku = existing.sku;
    const settings = await getRecord(tx, actor.organizationId, "settings", "settings");
    const product = buildProduct(input, existing?.id, noTax(settings) ? 0 : 1800);
    // Only an explicit manager action changes sale status, including on older-client edits.
    if (existing?.salesStopped) product.salesStopped = true;
    if (body.salesAction !== undefined) {
      allow(actor, ["owner", "manager"]);
      if (!existing || !["stop", "resume"].includes(body.salesAction))
        fail("Choose stop or resume for an existing product.");
      if (body.salesAction === "stop") {
        const listing = await getRecord(tx, actor.organizationId, "onlineListing", product.id);
        if (listing?.published || (listing?.sync && !["never", "unpublished"].includes(listing.sync.state)))
          fail("Unpublish this part from the online store and wait for synchronization before stopping sales.", 409);
        product.salesStopped = true;
      } else {
        delete product.salesStopped;
      }
    }
    for (const rule of product.fitments) validateFitment(rule);
    const products = await records(tx, actor.organizationId, "product");
    if (
      existing &&
      (existing.serialTracked !== product.serialTracked ||
        existing.type !== product.type)
    ) {
      if ((product.serialTracked || product.type === "service") && (await getRecord(tx, actor.organizationId, "onlineListing", product.id))?.published)
        fail("Unpublish this part from the online store before changing its tracking or item type.", 409);
      const stocked = await tx.query(
        "SELECT 1 FROM stock WHERE organization_id=$1 AND product_id=$2 AND quantity<>0 LIMIT 1",
        [actor.organizationId, product.id],
      );
      if (stocked.rows.length)
        fail(
          "Clear existing stock through audited operations before changing serial tracking or item type.",
          409,
        );
    }
    for (const component of product.components) {
      const part = products.find((p) => p.id === component.productId);
      if (!part || part.onlineOnly) fail("Choose an existing shop part or labour for every kit component.", 409);
    }
    // Stock mode is part of the provenance of invoices, purchases and reservations.
    if (existing && Boolean(product.onlineOnly) !== Boolean(existing.onlineOnly)) {
      const used = await tx.query(
        `SELECT 1 WHERE EXISTS (SELECT 1 FROM stock_ledger WHERE organization_id=$1 AND product_id=$2)
           OR EXISTS (SELECT 1 FROM records WHERE organization_id=$1
             AND kind IN ('invoice','purchaseBill','purchaseOrder','onlineOrder','hold','job','estimate','stockCount','transfer','product')
             AND NOT (kind='product' AND id=$2)
             AND jsonb_path_exists(data, 'strict $.** ? (@ == $ref)', jsonb_build_object('ref', $2::text)))`,
        [actor.organizationId, product.id],
      );
      if (used.rows.length) fail("This item is linked to a shop document, kit or stock movement. Create a separate SKU for the other sales channel.", 409);
    }
    // Imported stock may predate its movement ledger.
    if (existing && product.onlineOnly && !existing.onlineOnly) {
      const stocked = await tx.query(
        "SELECT 1 FROM stock WHERE organization_id=$1 AND product_id=$2 AND quantity<>0 LIMIT 1",
        [actor.organizationId, product.id],
      );
      if (stocked.rows.length)
        fail("This part has shop stock. Sell, return or adjust it to zero before making it online only.", 409);
    }
    const removed = await records(tx, actor.organizationId, "removedProduct");
    const codes = new CatalogCodes([...products, ...removed].filter((p) => p.id !== product.id));
    codes.check(product, existing);
    if (
      existing &&
      (await records(tx, actor.organizationId, "hold")).some((hold) =>
        hold.cart.lines.some((line: any) => line.productId === product.id),
      )
    )
      fail("Complete or release parked sales before editing this part.", 409);
    if (existing) {
      if (existing.lastPurchaseCost != null) product.lastPurchaseCost = existing.lastPurchaseCost;
      const changed = (["cost", "retailPrice"] as const).filter(field => product[field] !== existing[field]);
      await supersedeBillEconomics(tx, actor.organizationId, product.id, changed);
    }
    const statusChanged = Boolean(existing?.salesStopped) !== Boolean(product.salesStopped);
    await audit(tx, actor, "product", product.id, statusChanged
      ? (product.salesStopped ? "Stopped new sales" : "Resumed sales") : "Catalog update");
    const saved = await putRecord(tx, actor.organizationId, "product", product);
    await queueMagentoSync(tx, actor.organizationId, [product.id], "product");
    return saved;
  });
  for (const preview of [true, false]) {
    post(preview ? "products/import/preview" : "products/import", async (tx, actor, body) => {
      allow(actor, ["owner", "manager", "inventory"]);
      const org = actor.organizationId;
      const existing = await records(tx, org, "product");
      const removed = await records(tx, org, "removedProduct");
      const settings = await getRecord(tx, org, "settings", "settings");
      const result = previewCatalog(body.csv, new CatalogCodes([...existing, ...removed]), settings?.taxScheme === "india-gst", noTax(settings));
      if (preview) return { rows: result.rows, valid: result.valid };
      if (!result.valid) {
        const first = result.rows.find((row) => row.error)!;
        fail(`Row ${first.row}: ${first.error} Preview the file again before importing.`, 409);
      }
      for (const product of result.products) await putRecord(tx, org, "product", product);
      await audit(tx, actor, "catalog-import", "catalog", "Imported new parts from CSV", {
        productIds: result.products.map((p) => p.id),
      });
      return { imported: result.products.length };
    });
  }
  for (const restoring of [false, true]) {
    const source = restoring ? "removedProduct" : "product";
    const destination = restoring ? "product" : "removedProduct";
    post("products/:id/" + (restoring ? "restore" : "remove"), async (tx, actor, _body, params) => {
      allow(actor, ["owner", "manager"]);
      const part = await scoped(tx, actor, source, params.id);
      if (!restoring) {
        const used = await tx.query(
          `SELECT 1 WHERE EXISTS (SELECT 1 FROM stock WHERE organization_id=$1 AND product_id=$2)
           OR EXISTS (SELECT 1 FROM stock_ledger WHERE organization_id=$1 AND product_id=$2)
           OR EXISTS (SELECT 1 FROM records WHERE organization_id=$1
             AND kind NOT IN ('audit', 'catalogSnapshot') AND NOT (kind='product' AND id=$2)
             AND (id=$2 OR jsonb_path_exists(data, 'strict $.** ? (@ == $ref)', jsonb_build_object('ref', $2::text))))`,
          [actor.organizationId, part.id],
        );
        if (used.rows.length) fail("This part is linked to stock or another shop record and must stay in the catalog.", 409);
      }
      await tx.query("UPDATE records SET kind=$4 WHERE organization_id=$1 AND kind=$2 AND id=$3",
        [actor.organizationId, source, part.id, destination]);
      await audit(tx, actor, restoring ? "product-restore" : "product-remove", part.id, part.sku);
      return { id: part.id };
    });
  }
  // WS-B: customers are saved by routes/customers.ts (keeps credit limits).
  for (const kind of ["supplier"] as const)
    post(kind + "s", async (tx, actor, body) => {
      allow(actor, ["owner", "manager", "inventory"]);
      const entity = {
        id: body.id || id(kind),
        name: text(body.name, "name"),
        phone: String(body.phone || ""),
        email: emailAddress(body.email || "", false),
        address: multiline(body.address || "", "address"),
        taxRegistrationId: text(
          body.taxRegistrationId || "",
          "tax registration ID",
          false,
          100,
        ),
        stateCode: text(body.stateCode || "", "state code", false, 50),
        vehicle: body.vehicle || null,
      };
      const saved = body.id ? await scoped(tx, actor, kind, body.id) : null;
      // Old balance from before the POS (positive: we owe the supplier / the customer owes us).
      // Only owners and managers may set it; other edits keep the saved value.
      const mayEdit = ["owner", "manager"].includes(actor.role);
      Object.assign(entity, {
        openingBalance: mayEdit && body.openingBalance !== undefined
          ? integer(body.openingBalance, "Opening balance", -100000000000)
          : Number(saved?.openingBalance || 0),
        openingDate: (mayEdit && body.openingDate ? String(body.openingDate).slice(0, 10) : "") || saved?.openingDate || "",
      });
      return putRecord(tx, actor.organizationId, kind, entity);
    });
  post("locations", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const existing = body.id
      ? await scoped(tx, actor, "location", body.id)
      : undefined;
    const value = { ...existing, ...body };
    const location: any = {
      id: existing?.id || id("bin"),
      branchId: actor.branchId,
    };
    for (const key of ["area", "rack", "shelf", "bin"])
      location[key] = text(value[key], key);
    location.kind = value.kind || "sellable";
    if (!["sellable", "damaged", "warranty"].includes(location.kind))
      fail("Unknown bin kind.");
    if (existing && location.kind !== existing.kind)
      fail("Create a new bin to change its stock condition.");
    await audit(
      tx,
      actor,
      "location",
      location.id,
      "Location label update",
      location,
    );
    return putRecord(
      tx,
      actor.organizationId,
      "location",
      location,
      actor.branchId,
    );
  });
  post("fitments", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const product = await scoped(tx, actor, "product", body.productId);
    validateFitment(body);
    const rule = { ...body, id: body.id || id("fitment") };
    product.fitments = [
      ...product.fitments.filter((entry: any) => entry.id !== rule.id),
      rule,
    ];
    await putRecord(tx, actor.organizationId, "product", product);
    await audit(tx, actor, "fitment", product.id, "Fitment update", {
      source: rule.source,
    });
    return rule;
  });
  post("fitments/check", async (tx, actor, body) =>
    fitment(await scoped(tx, actor, "product", body.productId), body.vehicle),
  );
  const csvPreview = async (tx: Database, actor: Actor, body: any) => {
    let rows: any[];
    try {
      rows = parse(body.csv, {
        columns: true,
        skip_empty_lines: true,
        trim: true,
      });
    } catch {
      fail("CSV could not be parsed.");
    }
    if (rows.length > 10000) fail("Import at most 10,000 rows per batch.");
    const results: any[] = [];
    const duplicates = new Set<string>();
    for (let index = 0; index < rows.length; index++) {
      const row = {
        ...rows[index],
        yearFrom: Number(rows[index].yearFrom),
        yearTo: Number(rows[index].yearTo),
        exclusions: [],
      };
      const errors: string[] = [];
      try {
        validateFitment(row);
        await scoped(tx, actor, "product", row.productId);
      } catch (error: any) {
        errors.push(error.message);
      }
      const key = fitmentKey(row);
      if (duplicates.has(key)) errors.push("Duplicate row in this file.");
      duplicates.add(key);
      const product = await getRecord(
        tx,
        actor.organizationId,
        "product",
        row.productId,
      );
      results.push({
        row: index + 2,
        data: row,
        errors,
        duplicate: !!product?.fitments.some(
          (rule: any) => fitmentKey(rule) === key,
        ),
      });
    }
    return {
      rows: results,
      valid: results.every((row) => !row.errors.length),
      errors: results.flatMap((row) =>
        row.errors.map((message: string) => ({ row: row.row, message })),
      ),
    };
  };
  post("fitments/import/preview", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    return csvPreview(tx, actor, body);
  });
  post("fitments/import", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const preview = await csvPreview(tx, actor, body);
    if (!preview.valid) fail("Resolve row errors before importing.");
    if (!["skip", "replace"].includes(body.duplicateHandling))
      fail("Choose skip or replace duplicate handling.");
    let imported = 0;
    for (const row of preview.rows) {
      if (row.duplicate && body.duplicateHandling === "skip") continue;
      const product = await scoped(tx, actor, "product", row.data.productId);
      product.fitments = [
        ...product.fitments.filter(
          (rule: any) => fitmentKey(rule) !== fitmentKey(row.data),
        ),
        { ...row.data, id: id("fitment") },
      ];
      await putRecord(tx, actor.organizationId, "product", product);
      imported++;
    }
    await audit(tx, actor, "fitment-import", "catalog", "CSV import", {
      imported,
    });
    return { imported, skipped: preview.rows.length - imported };
  });
}
function validateFitment(rule: any) {
  text(rule.make, "make");
  text(rule.model, "model");
  integer(rule.yearFrom, "Start year", 1900, 2100);
  integer(rule.yearTo, "End year", rule.yearFrom, 2100);
  text(rule.source, "fitment source");
  for (const key of ["engine", "fuel", "trim", "drivetrain", "market"])
    if (rule[key] !== undefined) text(rule[key], key, false);
  if (rule.exclusions !== undefined && !Array.isArray(rule.exclusions))
    fail("Exclusions must be an array.");
  for (const key of ["effectiveFrom", "effectiveTo"])
    if (rule[key] && !/^\d{4}-\d{2}-\d{2}$/.test(rule[key]))
      fail("Effective dates must use YYYY-MM-DD.");
}
function fitmentKey(rule: any) {
  return [
    "productId",
    "make",
    "model",
    "yearFrom",
    "yearTo",
    "engine",
    "fuel",
    "trim",
    "drivetrain",
    "market",
  ]
    .map((key) => normalize(rule[key]))
    .join("|");
}
