import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, getRecord, putRecord } from "../db.js";
import {
  type Actor,
  allow,
  scoped,
  integer,
  text,
  fail,
  id,
  now,
  adjust,
  audit,
  inventory,
  idempotent,
  roundRatio,
} from "../domain.js";
import { reorderSuggestions, groupBySupplier } from "../replenishment.js";
import { supersedeBillEconomics } from "../bill-economics.js";
import { noteCost, costHikeThreshold } from "../cost-changes.js";
import { queueMagentoSync } from "../online-queue.js";

export function purchaseOrderRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("purchase-orders", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    await scoped(tx, actor, "supplier", body.supplierId);
    if (!Array.isArray(body.lines) || !body.lines.length)
      fail("Add purchase lines.");
    const suggestions = body.replenishment === true ? reorderSuggestions(
      await records(tx, actor.organizationId, "product"), await inventory(tx, actor),
      await records(tx, actor.organizationId, "location", actor.branchId),
      await records(tx, actor.organizationId, "purchaseOrder", actor.branchId),
    ) : null;
    const lines = [];
    const used = new Set<string>();
    for (const line of body.lines) {
      const product = await scoped(tx, actor, "product", line.productId);
      if (product.type === "service") fail("Choose a stock part for a purchase order.");
      if (suggestions && line.quantity > (suggestions.find(row => row.productId === product.id)?.suggestedQuantity ?? 0))
        fail("The reorder quantity changed. Refresh the dashboard and review the stock already on order.", 409);
      if (used.has(line.productId)) fail("Combine duplicate purchase lines.");
      used.add(line.productId);
      lines.push({
        productId: line.productId,
        quantity: integer(line.quantity, "Quantity", 1),
        cost: integer(line.cost, "Cost"),
        received: 0,
      });
    }
    const order = {
      id: id("po"),
      branchId: actor.branchId,
      supplierId: body.supplierId,
      lines,
      status: "open",
      createdAt: now(),
      userId: actor.id,
    };
    await audit(
      tx,
      actor,
      "purchase-order",
      order.id,
      "Purchase order created",
    );
    return putRecord(
      tx,
      actor.organizationId,
      "purchaseOrder",
      order,
      actor.branchId,
    );
  });
  app.get("/api/v1/purchase-orders/:id/receipts", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager", "inventory"]);
    return db.readSnapshot(async (tx) => {
      const order = await scoped(tx, actor, "purchaseOrder", request.params.id);
      const result = await tx.query(
        "SELECT data FROM records WHERE organization_id=$1 AND branch_id=$2 AND kind='purchaseReceipt' AND data->>'purchaseOrderId'=$3 ORDER BY created_at DESC,id DESC",
        [actor.organizationId, actor.branchId, order.id],
      );
      return { receipts: result.rows.map(({ data }) => data) };
    });
  });
  post("purchase-orders/:id/receive", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    return idempotent(
      tx,
      actor,
      body.transactionId,
      { purchaseOrderId: params.id, body },
      async () => {
        const order = await scoped(tx, actor, "purchaseOrder", params.id);
        if (order.status === "cancelled") fail("This purchase order was cancelled."); // WS-E
        if (!Array.isArray(body.lines) || !body.lines.length)
          fail("Select receipt lines.");
        const landedCost = integer(body.landedCost || 0, "Landed cost");
        const receiptId = id("receipt");
        const lines = [];
        let allocated = 0,
          cumulative = 0;
        const totalUnits = body.lines.reduce(
          (sum: number, line: any) =>
            sum + integer(line.quantity, "Quantity", 1),
          0,
        );
        for (const input of body.lines) {
          const line = order.lines.find(
            (line: any) => line.productId === input.productId,
          );
          if (!line) fail("Part is not on this purchase order.");
          const quantity = integer(
            input.quantity,
            "Received quantity",
            1,
            line.quantity - line.received,
          );
          const product = await scoped(tx, actor, "product", line.productId);
          // Online only: the goods go straight out to the website customer, so
          // the receipt is recorded without a bin and adds no shop stock.
          const onlineOnly = !!product.onlineOnly;
          const bin = onlineOnly ? null : await scoped(tx, actor, "location", input.binId);
          if (bin && bin.kind !== "sellable")
            fail("Purchases must be put away into a sellable bin.");
          cumulative += quantity;
          const next = roundRatio(landedCost, cumulative, totalUnits);
          const extra = next - allocated;
          allocated = next;
          // WS-E: the supplier's actual unit cost on this delivery (defaults to the
          // ordered cost), checked for a cost hike against the last purchase cost.
          const unitCost = input.cost === undefined || input.cost === null || input.cost === ""
            ? line.cost : integer(input.cost, "Unit cost");
          const costHike = await noteCost(tx, actor, product, unitCost, {
            kind: "receipt", id: receiptId, label: "Goods receipt", supplierId: order.supplierId,
          });
          await supersedeBillEconomics(tx, actor.organizationId, product.id, ["cost", "lastPurchaseCost"]);
          product.cost = unitCost + roundRatio(extra, 1, quantity);
          await putRecord(tx, actor.organizationId, "product", product);
          if (product.serialTracked) {
            if (
              !Array.isArray(input.serials) ||
              input.serials.length !== quantity ||
              new Set(input.serials).size !== quantity
            )
              fail("Receive one unique serial per unit.");
            for (const serial of input.serials) {
              text(serial, "serial");
              const serialId = product.id + ":" + serial;
              if (await getRecord(tx, actor.organizationId, "serial", serialId))
                fail("Serial already exists.");
              await putRecord(
                tx,
                actor.organizationId,
                "serial",
                {
                  id: serialId,
                  branchId: actor.branchId,
                  productId: product.id,
                  serial,
                  binId: bin!.id,
                  status: "available",
                },
                actor.branchId,
              );
            }
          }
          if (bin)
            await adjust(
              tx,
              actor,
              product.id,
              bin.id,
              quantity,
              "Goods receipt",
              receiptId,
            );
          line.received += quantity;
          lines.push({
            productId: product.id,
            sku: product.sku,
            name: product.name,
            category: product.category,
            quantity,
            binId: bin?.id || null,
            location: bin ? [bin.area, bin.rack, bin.shelf, bin.bin].filter(Boolean).join(" / ") : "Order from supplier (online only)",
            ...(onlineOnly ? { onlineOnly: true } : {}),
            cost: unitCost,
            landedCost: extra,
            ...(costHike ? { costHike } : {}),
          });
        }
        order.status = order.lines.every(
          (line: any) => line.received === line.quantity,
        )
          ? "received"
          : "partial";
        await putRecord(
          tx,
          actor.organizationId,
          "purchaseOrder",
          order,
          actor.branchId,
        );
        const receipt = {
          id: receiptId,
          branchId: actor.branchId,
          purchaseOrderId: order.id,
          supplierId: order.supplierId,
          lines,
          landedCost,
          createdAt: now(),
          userId: actor.id,
        };
        await audit(tx, actor, "goods-receipt", receiptId, "Goods received");
        return putRecord(
          tx,
          actor.organizationId,
          "purchaseReceipt",
          receipt,
          actor.branchId,
        );
      },
    );
  });

  // ---------- WS-E: reorder alerts → draft purchase orders ----------

  /** Draft purchase orders from the reorder alerts, one per usual supplier. */
  post("purchase-orders/from-suggestions", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const suggestions = reorderSuggestions(
      await records(tx, actor.organizationId, "product"), await inventory(tx, actor),
      await records(tx, actor.organizationId, "location", actor.branchId),
      await records(tx, actor.organizationId, "purchaseOrder", actor.branchId),
    ).filter((row) => row.suggestedQuantity > 0);
    let wanted = suggestions.map((row) => ({ ...row, quantity: row.suggestedQuantity }));
    if (Array.isArray(body.lines)) {
      if (!body.lines.length) fail("Choose the parts to order.");
      wanted = body.lines.map((input: any) => {
        const row = suggestions.find((entry) => entry.productId === input.productId);
        if (!row) fail("A chosen part no longer needs reordering. Refresh and review the list.", 409);
        return { ...row!, quantity: integer(input.quantity ?? row!.suggestedQuantity, "Quantity", 1, 1000000) };
      });
    }
    if (!wanted.length) fail("No part is below its reorder level.", 409);
    const { groups, noSupplier } = groupBySupplier(wanted);
    const created = [];
    for (const [supplierId, rows] of groups) {
      const supplier = await getRecord(tx, actor.organizationId, "supplier", supplierId);
      if (!supplier) {
        noSupplier.push(...rows);
        continue;
      }
      const lines = [];
      for (const row of rows) {
        const product = await scoped(tx, actor, "product", row.productId);
        lines.push({ productId: product.id, quantity: row.quantity, cost: Number(product.lastPurchaseCost ?? product.cost ?? 0), received: 0 });
      }
      const order = {
        id: id("po"),
        branchId: actor.branchId,
        supplierId,
        lines,
        status: "draft",
        createdAt: now(),
        userId: actor.id,
        note: "From reorder alerts",
      };
      await putRecord(tx, actor.organizationId, "purchaseOrder", order, actor.branchId);
      await audit(tx, actor, "purchase-order", order.id, "Draft purchase order from reorder alerts");
      created.push(order);
    }
    return {
      purchaseOrders: created,
      noSupplier: noSupplier.map((row) => ({ productId: row.productId, sku: row.sku, name: row.name })),
    };
  });

  /** A draft is sent to the supplier (it becomes an open order). */
  post("purchase-orders/:id/place", async (tx, actor, _body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const order = await scoped(tx, actor, "purchaseOrder", params.id);
    if (order.status !== "draft") fail("Only a draft purchase order can be placed.", 409);
    order.status = "open";
    order.placedAt = now();
    await audit(tx, actor, "purchase-order", order.id, "Purchase order placed");
    return putRecord(tx, actor.organizationId, "purchaseOrder", order, actor.branchId);
  });

  post("purchase-orders/:id/cancel", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const order = await scoped(tx, actor, "purchaseOrder", params.id);
    if (!["draft", "open"].includes(order.status) || order.lines.some((line: any) => (line.received || 0) > 0))
      fail("Only an order with nothing received can be cancelled.", 409);
    order.status = "cancelled";
    order.cancelledAt = now();
    await audit(tx, actor, "purchase-order-cancel", order.id, text(body.reason || "Cancelled", "reason", false, 300));
    return putRecord(tx, actor.organizationId, "purchaseOrder", order, actor.branchId);
  });

  /** Edit quantities or costs on a draft before placing it. */
  post("purchase-orders/:id/lines", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const order = await scoped(tx, actor, "purchaseOrder", params.id);
    if (order.status !== "draft") fail("Only a draft purchase order can be edited.", 409);
    if (!Array.isArray(body.lines) || !body.lines.length) fail("Keep at least one part on the order, or cancel it.");
    const used = new Set<string>();
    const lines = [];
    for (const input of body.lines) {
      const product = await scoped(tx, actor, "product", input.productId);
      if (product.type === "service") fail("Choose a stock part for a purchase order.");
      if (used.has(product.id)) fail("Combine duplicate purchase lines.");
      used.add(product.id);
      lines.push({ productId: product.id, quantity: integer(input.quantity, "Quantity", 1), cost: integer(input.cost ?? product.cost, "Cost"), received: 0 });
    }
    order.lines = lines;
    return putRecord(tx, actor.organizationId, "purchaseOrder", order, actor.branchId);
  });

  // ---------- WS-E: cost changes found while receiving ----------

  app.get("/api/v1/cost-changes", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager", "inventory"]);
    const all = await records(db, actor.organizationId, "costChange", actor.branchId);
    const status = String(request.query?.status || "open");
    const settings = await getRecord(db, actor.organizationId, "settings", "settings");
    return {
      threshold: costHikeThreshold(settings),
      changes: all.filter((change) => status === "all" || change.status === status).reverse().slice(0, 500),
    };
  });

  /** Quick action: set a new selling price for a part whose cost rose. */
  post("cost-changes/:id/apply", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const change = await scoped(tx, actor, "costChange", params.id);
    if (change.status !== "open") fail("This cost change is already resolved.", 409);
    const product = await scoped(tx, actor, "product", change.productId);
    const retailPrice = integer(body.retailPrice ?? change.suggestedPrice, "Selling price", 1);
    const before = product.retailPrice;
    await supersedeBillEconomics(tx, actor.organizationId, product.id, ["retailPrice"]);
    product.retailPrice = retailPrice;
    await putRecord(tx, actor.organizationId, "product", product);
    await queueMagentoSync(tx, actor.organizationId, [product.id], "Price change");
    await audit(tx, actor, "price-change", product.id, `Cost rose on ${change.sourceLabel}`, { from: before, to: retailPrice });
    const updated = { ...change, status: "priceUpdated", newRetailPrice: retailPrice, resolvedAt: now(), resolvedBy: actor.id };
    return putRecord(tx, actor.organizationId, "costChange", updated, actor.branchId);
  });

  post("cost-changes/:id/dismiss", async (tx, actor, _body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const change = await scoped(tx, actor, "costChange", params.id);
    const updated = { ...change, status: "dismissed", resolvedAt: now(), resolvedBy: actor.id };
    return putRecord(tx, actor.organizationId, "costChange", updated, actor.branchId);
  });

  /** How much a cost may rise (basis points) before it is flagged. */
  post("purchasing/settings", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    const settings = (await getRecord(tx, actor.organizationId, "settings", "settings"))!;
    settings.purchasing = { ...(settings.purchasing || {}), costHikeThreshold: integer(body.costHikeThreshold, "Cost alert threshold", 0, 10000) };
    await putRecord(tx, actor.organizationId, "settings", settings);
    return { costHikeThreshold: settings.purchasing.costHikeThreshold };
  });

  // ---------- WS-E: received parts on the website ----------

  /** Queues stock, price and photos of received parts for the Magento sync. */
  post("purchasing/sync-online", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const ids: string[] = Array.isArray(body.productIds) ? [...new Set<string>(body.productIds.map(String))] : [];
    if (!ids.length || ids.length > 300) fail("Choose the received parts to update online.");
    await queueMagentoSync(tx, actor.organizationId, ids, "Goods received");
    return { parts: await syncStatus(tx, actor, ids) };
  });

  app.get("/api/v1/purchasing/sync-status", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager", "inventory"]);
    const ids = String(request.query?.productIds || "").split(",").map((v) => v.trim()).filter(Boolean).slice(0, 300);
    return { parts: await syncStatus(db, actor, ids) };
  });
}

/** WS-E: Magento state of each part: not online, waiting to send, sent, or failed. */
async function syncStatus(db: Database, actor: Actor, productIds: string[]) {
  const settings = await getRecord(db, actor.organizationId, "settings", "settings");
  const connected = !!settings?.integrations?.magento?.enabled;
  const parts = [];
  for (const productId of productIds) {
    const listing = await getRecord(db, actor.organizationId, "onlineListing", productId);
    const job = await getRecord(db, actor.organizationId, "magentoJob", productId);
    const online = !!listing && (listing.published || listing.sync?.magentoId);
    parts.push({
      productId,
      state: !connected ? "not-connected" : !online ? "not-online" : job ? (job.error ? "error" : "queued") : listing!.sync?.state || "synced",
      error: job?.error || listing?.sync?.error || null,
      at: listing?.sync?.at || null,
      qty: listing?.sync?.qty ?? null,
    });
  }
  return parts;
}
