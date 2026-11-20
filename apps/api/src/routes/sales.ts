import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, getRecord, putRecord } from "../db.js";
import { allow, scoped, integer, fail, id, now, audit, inventory, idempotent } from "../domain.js";
import { finalizeSale, returnInvoice } from "../sales.js";
import { queueMagentoSync } from "../online-queue.js";

export function salesRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("invoices", async (tx, actor, body) =>
    idempotent(tx, actor, body.transactionId, body, () =>
      finalizeSale(tx, actor, body),
    ),
  );
  post("invoices/:id/returns", async (tx, actor, body, params) =>
    idempotent(
      tx,
      actor,
      body.transactionId,
      { invoiceId: params.id, body },
      () => returnInvoice(tx, actor, params.id, body),
    ),
  );
  post("invoices/:id/void", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const invoice = await scoped(tx, actor, "invoice", params.id);
    if (
      (await records(tx, actor.organizationId, "return", actor.branchId)).some(
        (item) => item.invoiceId === invoice.id,
      )
    )
      fail("Void requires an invoice with no prior returns.");
    if (
      (
        await records(tx, actor.organizationId, "coreReturn", actor.branchId)
      ).some((item) => item.invoiceId === invoice.id)
    )
      fail("Use line credit notes after a prior core refund.");
    // A sale made on the customer's account is reversed on that account unless told otherwise.
    if (!body.refundType && (invoice.tenders || []).some((t: any) => t.type === "Credit"))
      body.refundType = "Credit";
    const credit = await returnInvoice(
      tx,
      actor,
      invoice.id,
      {
        ...body,
        transactionId: body.transactionId || id("void"),
        condition: "sellable",
        lines: invoice.lines.map((line: any) => ({
          lineId: line.id,
          quantity: line.qty,
          binId: line.binId,
          serials: line.serials,
        })),
      },
      true,
    );
    let coreRefundTotal = 0;
    for (const line of invoice.lines.filter(
      (line: any) => line.coreCharge > 0,
    )) {
      const core = {
        id: id("core"),
        branchId: actor.branchId,
        invoiceId: invoice.id,
        productId: line.productId,
        quantity: line.qty,
        total: line.qty * line.coreCharge,
        reason: body.reason,
        refundType: body.refundType || "Cash",
        createdAt: now(),
        userId: actor.id,
        shiftId: credit.shiftId,
        voidId: credit.id,
      };
      await putRecord(
        tx,
        actor.organizationId,
        "coreReturn",
        core,
        actor.branchId,
      );
      await audit(tx, actor, "core-void", core.id, body.reason, {
        invoiceId: invoice.id,
      });
      coreRefundTotal += core.total;
    }
    return {
      ...credit,
      coreRefundTotal,
      totalRefund: credit.total + coreRefundTotal,
    };
  });
  post("holds", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "cashier"]);
    const cart = body.cart;
    if (
      !Array.isArray(cart?.lines) ||
      !cart.lines.length ||
      cart.lines.length > 200
    )
      fail("Park between one and 200 cart lines.");
    const previous = body.id
      ? await scoped(tx, actor, "hold", body.id)
      : undefined;
    const stock = await inventory(tx, actor);
    const quantities = new Map<string, number>();
    for (const line of cart.lines) {
      const quantity = integer(line.qty, "Quantity", 1, 9999);
      line.qty = quantity;
      const product = await scoped(tx, actor, "product", line.productId);
      if (product.salesStopped) fail("New sales are stopped for " + product.sku + ".", 409);
      if (product.type === "service") continue;
      const bin = await scoped(tx, actor, "location", line.binId);
      if (bin.kind !== "sellable") fail("Park stock from a sellable bin.");
      const key = line.productId + "|" + line.binId;
      quantities.set(key, (quantities.get(key) || 0) + quantity);
      const own = (previous?.cart.lines || [])
        .filter(
          (entry: any) =>
            entry.productId === line.productId && entry.binId === line.binId,
        )
        .reduce((sum: number, entry: any) => sum + entry.qty, 0);
      const settingsNow = await getRecord(tx, actor.organizationId, "settings", "settings");
      if (
        (settingsNow?.features?.negativeStock === false ||
          (await getRecord(tx, actor.organizationId, "product", line.productId))?.serialTracked) &&
        (stock.find(
          (item) =>
            item.productId === line.productId && item.binId === line.binId,
        )?.available || 0) +
          own <
        quantities.get(key)!
      )
        fail("Insufficient stock to park this bill.", 409);
    }
    const hold = {
      id: previous?.id || id("hold"),
      branchId: actor.branchId,
      userId: actor.id,
      cart,
      createdAt: previous?.createdAt || now(),
    };
    const savedHold = await putRecord(tx, actor.organizationId, "hold", hold, actor.branchId);
    // Parked sales hold stock, so the website shows less.
    await queueMagentoSync(
      tx,
      actor.organizationId,
      [...cart.lines, ...(previous?.cart.lines || [])].map((line: any) => line.productId),
      "hold",
      actor.branchId,
    );
    return savedHold;
  });
  app.delete("/api/v1/holds/:id", async (request: any) =>
    db.transaction(async (tx) => {
      const actor = request.actor;
      allow(actor, ["owner", "manager", "cashier"]);
      const released = await scoped(tx, actor, "hold", request.params.id);
      await queueMagentoSync(
        tx,
        actor.organizationId,
        (released.cart?.lines || []).map((line: any) => line.productId),
        "hold",
        actor.branchId,
      );
      await tx.query(
        "DELETE FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3",
        [actor.organizationId, "hold", request.params.id],
      );
      return { deleted: true };
    }),
  );
}
