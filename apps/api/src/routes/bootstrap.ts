import type { FastifyInstance } from "fastify";
import { createHash } from "node:crypto";
import type { Database } from "../db.js";
import { records, getRecord } from "../db.js";
import { type Actor, now, inventory } from "../domain.js";
import { reorderSuggestions } from "../replenishment.js";
import { productImages } from "../product-images.js";
import { partyBalances } from "../purchasing.js";
import { invoiceProfile } from "../settings.js";
import { publicUser } from "./auth-pin.js"; // WS-D

export function bootstrapRoutes(app: FastifyInstance, db: Database) {
  const readBootstrap = async (db: Database, actor: Actor) => {
    const data: any = {
      lastSync: now(),
      organization: await getRecord(
        db,
        actor.organizationId,
        "organization",
        actor.organizationId,
      ),
      branch: await getRecord(
        db,
        actor.organizationId,
        "branch",
        actor.branchId,
      ),
      user: actor,
    };
    const user = (await getRecord(db, actor.organizationId, "user", actor.id))!;
    // WS-D: no password or PIN hashes; managers see this branch's staff to set counter PINs.
    data.users =
      actor.role === "owner"
        ? (await records(db, actor.organizationId, "user")).map(publicUser)
        : actor.role === "manager"
          ? (await records(db, actor.organizationId, "user"))
              .filter((entry) => entry.branchIds.includes(actor.branchId))
              .map((entry) => {
                const { id, name, role, active, hasPin } = publicUser(entry);
                return { id, name, role, active, hasPin };
              })
          : [];
    data.branches = (await records(db, actor.organizationId, "branch")).filter(
      (branch) => user.branchIds.includes(branch.id),
    );
    for (const [plural, kind, scope] of [
      ["products", "product", ""],
      ["vehicles", "vehicle", ""],
      ["customers", "customer", ""],
      ["suppliers", "supplier", ""],
      ["locations", "location", "branch"],
      ["purchaseOrders", "purchaseOrder", "branch"],
      ["invoices", "invoice", "branch"],
      ["returns", "return", "branch"],
      ["shifts", "shift", "branch"],
      ["holds", "hold", "branch"],
      ["transfers", "transfer", ""],
      ["warrantyClaims", "warranty", "branch"],
      ["coreReturns", "coreReturn", "branch"],
      ["conflicts", "conflict", "branch"],
      ["devices", "device", "branch"],
      ["audit", "audit", "branch"],
      // WS-C (workshop)
      ["customerVehicles", "customerVehicle", ""],
      ["estimates", "estimate", "branch"],
      ["jobs", "job", "branch"],
    ])
      data[plural] = await records(
        db,
        actor.organizationId,
        kind,
        scope === "branch" ? actor.branchId : undefined,
      );
    if (actor.role === "inventory") {
      data.shifts = [];
      data.audit = data.audit.filter((entry: any) => entry.action !== "cash-in" && entry.action !== "cash-out");
    }
    if (["owner", "manager", "cashier"].includes(actor.role)) {
      const entries = await records(db, actor.organizationId, "cashMovement", actor.branchId);
      data.cashMovements = actor.role === "cashier" ? entries.filter(entry => entry.userId === actor.id) : entries;
    }
    if (["owner", "manager", "inventory"].includes(actor.role)) {
      const counts = await db.query("SELECT data FROM records WHERE organization_id=$1 AND branch_id=$2 AND kind='stockCount' " +
        "AND data->>'status' IN ('counting','review') AND ($3::text IS NULL OR data->>'startedBy'=$3) ORDER BY created_at DESC",
        [actor.organizationId, actor.branchId, actor.role === "inventory" ? actor.id : null]);
      data.stockCounts = counts.rows.map(row => row.data);
    }
    data.transfers = data.transfers.filter(
      (transfer: any) =>
        transfer.branchId === actor.branchId ||
        transfer.destinationBranchId === actor.branchId,
    );
    if (actor.role === "cashier") {
      data.audit = [];
      data.shifts = data.shifts.filter((shift: any) => shift.userId === actor.id);
      data.conflicts = [];
      data.invoices = data.invoices.filter(
        (invoice: any) => invoice.cashierId === actor.id,
      );
    }
    if (["owner", "manager"].includes(actor.role)) {
      data.removedProducts = (await records(db, actor.organizationId, "removedProduct"))
        .map(({ id, sku, name }) => ({ id, sku, name }));
    }
    data.stock = await inventory(db, actor);
    if (actor.role !== "cashier") {
      data.reorderSuggestions = reorderSuggestions(data.products, data.stock, data.locations, data.purchaseOrders);
    }
    data.onlineListings = ["owner", "manager"].includes(actor.role)
      ? await records(db, actor.organizationId, "onlineListing")
      : [];
    data.productImages = await productImages(db, actor.organizationId);
    // Purchasing and party balances (customer balances are for everyone who sells).
    const stockRole = actor.role !== "cashier";
    data.purchaseBills = stockRole
      ? (await records(db, actor.organizationId, "purchaseBill", actor.branchId)).slice(-500)
      : [];
    data.purchaseReturns = stockRole
      ? (await records(db, actor.organizationId, "purchaseReturn", actor.branchId)).slice(-300)
      : [];
    data.partyPayments = (await records(db, actor.organizationId, "partyPayment"))
      .filter((p) => stockRole || p.partyKind === "customer")
      .slice(-500);
    data.partyBalances = {
      customers: await partyBalances(db, actor.organizationId, "customer"),
      suppliers: stockRole ? await partyBalances(db, actor.organizationId, "supplier") : {},
    };
    data.onlineOrders = ["owner", "manager"].includes(actor.role)
      ? (await records(db, actor.organizationId, "onlineOrder", actor.branchId)).slice(-300)
      : [];
    if (["owner", "manager"].includes(actor.role)) {
      const cursor = await getRecord(db, actor.organizationId, "magentoCursor", "orders");
      data.onlineOrdersCheck = cursor ? { at: cursor.checkedAt, error: cursor.error } : null;
      data.magentoCheck = (await getRecord(db, actor.organizationId, "magentoCheck", "latest")) || null;
    }
    data.settings = await getRecord(
      db,
      actor.organizationId,
      "settings",
      "settings",
    );
    data.catalogRevision = createHash("sha256")
      .update(
        JSON.stringify({
          products: data.products,
          customers: data.customers,
          settings: {
            ...invoiceProfile(data.settings, data.branch),
            roundingIncrement: data.settings.roundingIncrement,
            invoicePrefix: data.settings.invoicePrefix,
          },
          branchId: actor.branchId,
        }),
      )
      .digest("hex");
    const cached = await db.query(
      "SELECT 1 FROM records WHERE organization_id=$1 AND kind='catalogSnapshot' AND id=$2",
      [actor.organizationId, data.catalogRevision],
    );
    const catalog = cached.rows.length ? null : {
      id: data.catalogRevision,
      products: data.products,
      customers: data.customers,
      settings: { ...data.settings },
      branch: data.branch,
      branchId: actor.branchId,
      issuedAt: now(),
    };
    if (actor.role === "cashier") {
      data.products = data.products.map(({ cost, ...product }: any) => product);
      data.invoices = data.invoices.map(({ cost, ...invoice }: any) => ({
        ...invoice,
        lines: invoice.lines.map(({ cost, ...line }: any) => line),
      }));
      data.purchaseOrders = [];
      const ownInvoices = new Set(data.invoices.map((invoice: any) => invoice.id));
      data.returns = data.returns.filter(
        (entry: any) => entry.userId === actor.id || ownInvoices.has(entry.invoiceId),
      );
      data.coreReturns = data.coreReturns.filter(
        (entry: any) => entry.userId === actor.id || ownInvoices.has(entry.invoiceId),
      );
    }
    return { data, catalog };
  };
  app.get("/api/v1/bootstrap", async (request: any) => {
    const actor: Actor = request.actor;
    const { data, catalog } = await db.readSnapshot((snapshot) => readBootstrap(snapshot, actor));
    if (catalog) {
      await db.query(
        "INSERT INTO records(id,organization_id,kind,data) VALUES($1,$2,'catalogSnapshot',$3) ON CONFLICT DO NOTHING",
        [catalog.id, actor.organizationId, JSON.stringify(catalog)],
      );
    }
    return data;
  });
}
