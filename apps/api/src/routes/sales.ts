import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, putRecord } from "../db.js";
import { allow, scoped, fail, id, now, audit, idempotent } from "../domain.js";
import { finalizeSale, returnInvoice } from "../sales.js";

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
  // Parked sales (holds) moved to routes/holds.ts (WS-A).
}
