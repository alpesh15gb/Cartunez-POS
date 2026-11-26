// WS-B: Instant exchange at the counter.
//
// The register sends the items coming back as `returnRef` lines (in `lines`
// with kind "returnRef", or in `returns`), next to the new items:
//   { kind: "returnRef", invoiceId, lineId, qty, disposition, binId?, serials?, supplierId? }
// In the same transaction as the sale, this hook issues the GST credit note
// against the original invoice (stock goes back per disposition) and sets the
// credit against the new invoice as an "Exchange" tender. The customer pays the
// difference with ordinary tenders; when the credit is larger, the excess is
// refunded per original tender (returns.ts refundBreakdown): the Cash/Card/UPI
// part by `exchangeRefundType` through the sale's shift, account parts to the
// customer's account and online parts to the website.
// Other body fields: returnApprovalId (cashiers: a manager's "return" approval
// for this sale's transaction ID), returnReason.
import { getRecord } from "../db.js";
import { fail, scoped } from "../domain.js";
import { registerSaleHook } from "../sale-pipeline.js";
import type { SaleContext } from "../sale-types.js";
import { returnInvoice } from "../returns.js";

export const EXCHANGE_TENDER = "Exchange";

/** The exchange return lines of a checkout request. */
export function exchangeLines(body: any): any[] {
  const inLines = Array.isArray(body?.lines) ? body.lines.filter((line: any) => line?.kind === "returnRef") : [];
  const extra = Array.isArray(body?.returns) ? body.returns : [];
  return [...inLines, ...extra];
}

registerSaleHook({
  name: "ws-b-exchange",
  tenderTypes: [EXCHANGE_TENDER],
  expandLines(ctx) {
    if (!exchangeLines(ctx.body).length) return;
    if (ctx.body.offline) fail("Exchanges need a connection to the server.", 403);
    if (!ctx.lines.length)
      fail("Add the replacement item to the bill. To give money back without a new sale, use Orders › Returns.");
  },
  async validateTenders(ctx: SaleContext) {
    if (ctx.tenders.some((tender) => tender.type === EXCHANGE_TENDER))
      fail("Exchange credit is added automatically from the returned items.");
    const items = exchangeLines(ctx.body);
    if (!items.length) return;
    const invoiceIds = [...new Set(items.map((item) => String(item.invoiceId || "")))];
    if (invoiceIds.length !== 1 || !invoiceIds[0])
      fail("Exchange items from one original bill at a time.");
    const original = await scoped(ctx.db, ctx.actor, "invoice", invoiceIds[0]);
    if ((original.customerId || null) !== (ctx.body.customerId || null))
      fail("The replacement sale must use the same customer as the original invoice.", 409);
    const credit = await returnInvoice(
      ctx.db,
      ctx.actor,
      invoiceIds[0],
      {
        transactionId: ctx.body.transactionId,
        approvalId: ctx.body.returnApprovalId,
        reason: ctx.body.returnReason || "Exchange",
        // Unset: Cash. Account, advance and online portions of the old bill go back the way they were paid.
        refundType: ctx.body.exchangeRefundType || undefined,
        lines: items.map((item) => ({
          lineId: item.lineId,
          quantity: item.qty ?? item.quantity,
          disposition: item.disposition || "restock",
          binId: item.binId || undefined,
          serials: item.serials || [],
          supplierId: item.supplierId,
        })),
      },
      false,
      // The cash back goes through the sale's till, so a manager can exchange on a cashier's till.
      { exchangeTotal: ctx.total, shift: ctx.shift },
    );
    // returnInvoice took the next credit-note number; keep the settings the sale
    // will save (next invoice number) from writing the old counter back.
    const fresh = (await getRecord(ctx.db, ctx.actor.organizationId, "settings", "settings"))!;
    ctx.settings.nextCreditNote = fresh.nextCreditNote;
    ctx.currentSettings.nextCreditNote = fresh.nextCreditNote;
    ctx.state.exchange = credit;
    if (credit.exchangeApplied > 0)
      ctx.tenders.push({ type: EXCHANGE_TENDER, amount: credit.exchangeApplied, confirmed: true, reference: credit.number });
  },
  beforePersist(ctx) {
    const credit = ctx.state.exchange;
    if (!credit || !ctx.invoice) return;
    ctx.invoice.exchange = {
      returnId: credit.id,
      creditNoteNumber: credit.number,
      originalInvoiceId: credit.invoiceId,
      originalInvoiceNumber: credit.invoiceNumber,
      credit: credit.total,
      applied: credit.exchangeApplied,
      refund: credit.refundTotal,
      refundType: credit.refundType,
      refunds: credit.refunds,
    };
  },
  // Credit notes are immutable once written, so the link back is the shared
  // transactionId (credit note and new invoice carry the same one) plus invoice.exchange.
});
