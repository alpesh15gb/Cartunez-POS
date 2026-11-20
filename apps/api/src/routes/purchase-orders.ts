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
import { reorderSuggestions } from "../replenishment.js";

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
          const bin = await scoped(tx, actor, "location", input.binId);
          if (bin.kind !== "sellable")
            fail("Purchases must be put away into a sellable bin.");
          cumulative += quantity;
          const next = roundRatio(landedCost, cumulative, totalUnits);
          const extra = next - allocated;
          allocated = next;
          product.cost = line.cost + roundRatio(extra, 1, quantity);
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
                  binId: bin.id,
                  status: "available",
                },
                actor.branchId,
              );
            }
          }
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
            binId: bin.id,
            location: [bin.area, bin.rack, bin.shelf, bin.bin].filter(Boolean).join(" / "),
            cost: line.cost,
            landedCost: extra,
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
}
