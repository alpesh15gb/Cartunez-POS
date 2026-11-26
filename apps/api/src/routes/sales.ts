import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, putRecord } from "../db.js";
import { allow, scoped, fail, id, now, audit, idempotent } from "../domain.js";
import { finalizeSale, returnInvoice } from "../sales.js";
import { refundBreakdown, refundTypeOf } from "../returns.js";
import { onlineInvoiceVoided } from "../fulfilment.js"; // WS-E

export function salesRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("invoices", async (tx, actor, body) => {
    if (body.offline === true)
      fail("Offline sales must be submitted through the sync route for conflict review.", 403);
    return idempotent(tx, actor, body.transactionId, body, () =>
      finalizeSale(tx, actor, body),
    );
  });
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
    // The refund follows the original tenders (returns.ts refundBreakdown): account
    // portions go back on the account, Online to the website, the rest by refundType
    // (or, with none given, by each original tender — same default as returns).
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
    await onlineInvoiceVoided(tx, actor, invoice); // WS-E: an online order goes back to "To pick" (fulfilment.ts)
    let coreRefundTotal = 0;
    const payout = new Map<string, number>(credit.refunds.map((part: { type: string; amount: number }) => [part.type, part.amount]));
    let credited = credit.total;
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
        refunds: refundBreakdown(invoice, credited, line.qty * line.coreCharge, body.refundType || ""),
        createdAt: now(),
        userId: actor.id,
        shiftId: credit.shiftId,
        voidId: credit.id,
      };
      (core as any).refundType = refundTypeOf(core.refunds, body.refundType || "Cash");
      credited += core.total;
      for (const part of core.refunds) payout.set(part.type, (payout.get(part.type) || 0) + part.amount);
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
    // A job billed on this invoice goes back to "ready" so it can be billed again.
    // (Imported on use so this module does not change the order checkout hooks register in.)
    if (invoice.jobId) await (await import("./jobs.js")).reopenVoidedJob(tx, actor, invoice);
    return {
      ...credit,
      coreRefundTotal,
      totalRefunds: [...payout].map(([type, amount]) => ({ type, amount })),
      totalRefund: credit.total + coreRefundTotal,
    };
  });
  // Parked sales (holds) moved to routes/holds.ts (WS-A).
}
