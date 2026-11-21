// WS-E: website orders invoiced by the POS (Online orders › Pick & pack).
//
// The fulfilment desk (fulfilment.ts) runs the normal checkout pipeline with a
// body it builds itself. This hook makes that sale an online sale:
//   - it runs on the branch's "online" till, which is not a cash drawer: the
//     till record has no branchId column, so it never appears in shift lists,
//     shift cash or the drawer reports;
//   - lines are priced at what the customer paid on the website;
//   - the payment is the "Online" tender (paid on the website, not drawer money)
//     or, for cash on delivery, "Credit" on the customer's account until the
//     courier's money is recorded;
//   - the invoice is marked channel "online" with the website order it bills.
// Counter sales cannot use the online till or the "Online" tender.
import { fail, roundRatio } from "../domain.js";
import { registerSaleHook } from "../sale-pipeline.js";
import type { SaleContext, SaleHook } from "../sale-types.js";

/** Bodies built by the fulfilment desk. Request bodies can never be in this set. */
const fulfilmentBodies = new WeakSet<object>();

/** Marks a checkout body as an online-order invoice built by the fulfilment desk. */
export function onlineSaleBody<T extends object>(body: T): T {
  fulfilmentBodies.add(body);
  return body;
}

export const isOnlineSale = (ctx: SaleContext) => fulfilmentBodies.has(ctx.body);

/** Id of the branch's online till (one per branch, never closed). */
export const onlineShiftId = (branchId: string) => `online-shift-${branchId}`;

export const ONLINE_TENDER = "Online";

function checkTill(ctx: SaleContext) {
  const onlineTill = ctx.shift?.channel === "online";
  if (isOnlineSale(ctx)) {
    if (!onlineTill || ctx.shift.onlineBranchId !== ctx.actor.branchId)
      fail("Online orders are invoiced on the branch's online till.", 409);
  } else if (onlineTill) {
    fail("This till is for website orders. Invoice them from Online orders › Pick & pack.", 409);
  }
}

export const onlineChannelHook: SaleHook = {
  name: "online-channel",
  tenderTypes: [ONLINE_TENDER],
  validateLine(ctx, input, line) {
    checkTill(ctx);
    if (!isOnlineSale(ctx) || input.onlinePrice === undefined) return;
    // The website price includes GST. Exclusive-tax invoices carry the price before GST.
    const paid = Math.max(0, Math.round(Number(input.onlinePrice) || 0));
    line.unitPrice = ctx.profile.taxMode === "inclusive" ? paid : roundRatio(paid, 10000, 10000 + (line.taxRate || 0));
    line.subtotal = line.unitPrice * line.qty;
  },
  validateTenders(ctx) {
    const online = isOnlineSale(ctx);
    if (!online) {
      if (ctx.tenders.some((tender) => tender.type === ONLINE_TENDER))
        fail('"Online" payments are recorded only for website orders.');
      return;
    }
    if (ctx.tenders.length !== 1 || ![ONLINE_TENDER, "Credit"].includes(ctx.tenders[0].type))
      fail("A website order is paid online, or on delivery (cash on delivery).");
    // The customer already paid (or will pay) the invoice total.
    ctx.tenders[0].amount = ctx.total;
    ctx.tenders[0].confirmed = true;
  },
  beforePersist(ctx) {
    if (!isOnlineSale(ctx)) return;
    const order = ctx.body.onlineOrder || {};
    Object.assign(ctx.invoice!, {
      channel: "online",
      onlineOrderId: order.id,
      onlineOrderNumber: order.number,
      paymentMethod: order.paymentMethod || "",
      cashOnDelivery: ctx.tenders[0].type === "Credit",
    });
  },
};

registerSaleHook(onlineChannelHook);
