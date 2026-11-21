// WS-E: website orders invoiced by the POS (Online orders › Pick & pack).
//
// The fulfilment desk (fulfilment.ts) runs the normal checkout pipeline with a
// body it builds itself. This hook makes that sale an online sale:
//   - it runs on the branch's "online" till, which is not a cash drawer: the
//     till record has no branchId column, so it never appears in shift lists,
//     shift cash or the drawer reports;
//   - lines are priced at what the customer paid on the website: each line is
//     given its Magento row total (onlineRowTotal, GST included) and the last
//     line takes any residual paise, so the POS total equals Magento's
//     grand_total (body.onlineTotal);
//   - the payment is the "Online" tender only for methods a payment gateway has
//     already collected (Magento settings › prepaidMethods). Cash on delivery
//     and bank transfer / UPI are "Credit" on the customer's account until the
//     courier's money or the customer's transfer is recorded;
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
    if (!isOnlineSale(ctx)) return;
    if (input.onlineRowTotal !== undefined) {
      // The Magento row total (GST included) for these units.
      const target = Math.max(0, Math.round(Number(input.onlineRowTotal) || 0));
      const rate = line.taxRate || 0;
      let subtotal = target;
      if (ctx.profile.taxMode !== "inclusive") {
        // Exclusive tax: the amount before GST whose total with GST is closest to the row total.
        const base = roundRatio(target, 10000, 10000 + rate);
        let best = Infinity;
        for (const s of [base, base - 1, base + 1, base - 2, base + 2]) {
          if (s < 0) continue;
          const off = Math.abs(s + roundRatio(s, rate, 10000) - target);
          if (off < best) [best, subtotal] = [off, s];
        }
      }
      line.subtotal = subtotal;
      line.unitPrice = Math.round(subtotal / line.qty);
      return;
    }
    if (input.onlinePrice === undefined) return;
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
      fail("A website order is paid online, or later on the customer's account (cash on delivery, bank transfer or UPI).");
    // The POS total equals the website's grand total: residual paise (rounding
    // of per-line GST) go on the last line as rounding.
    const target = ctx.body.onlineTotal;
    if (target !== undefined && ctx.lines.length) {
      const diff = Math.round(Number(target)) - ctx.total;
      const allowed = Math.max(200, Number(ctx.settings.roundingIncrement || 1));
      if (Math.abs(diff) > allowed)
        fail(
          `The POS invoice comes to ₹${(ctx.total / 100).toFixed(2)} but the website order total is ₹${(Number(target) / 100).toFixed(2)}. ` +
            "Check the order's prices, discounts and extra charges in Magento.",
          409,
        );
      if (diff) {
        const last = ctx.lines[ctx.lines.length - 1];
        last.rounding = (last.rounding || 0) + diff;
        last.total = (last.total || 0) + diff;
        ctx.rounding += diff;
        ctx.total += diff;
      }
    }
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
      paymentKind: order.paymentKind || (ctx.tenders[0].type === "Credit" ? "cod" : "prepaid"),
      cashOnDelivery: ctx.tenders[0].type === "Credit" && (order.paymentKind || "cod") === "cod",
    });
  },
};

registerSaleHook(onlineChannelHook);
