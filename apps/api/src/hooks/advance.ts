// WS-B: Paying from a customer's advance.
//
// Advances are taken with POST customers/:id/advances (routes/customers.ts) and
// sit on the customer's account as a negative balance. The "Advance" tender
// uses that money on a bill: at most what is held for the customer (advances
// and store credit from returns). The amount is recorded as
// `invoice.advanceApplied` and shows in the ledger as "Advance used".
import { fail } from "../domain.js";
import { registerSaleHook } from "../sale-pipeline.js";
import { availableAdvance, rupees } from "../customer-account.js";

registerSaleHook({
  name: "ws-b-advance",
  tenderTypes: ["Advance"],
  async validateTenders(ctx) {
    const advance = ctx.tenders.filter((t) => t.type === "Advance").reduce((sum, t) => sum + t.amount, 0);
    if (!ctx.tenders.some((t) => t.type === "Advance")) return;
    if (!ctx.body.customerId || !ctx.customer) fail("Choose the customer before paying from their advance.");
    if (ctx.body.offline) fail("Paying from an advance needs a connection to the server.", 403);
    if (advance < 1) fail("Enter the amount to use from the advance.");
    const available = await availableAdvance(ctx.db, ctx.actor.organizationId, ctx.customer.id);
    if (advance > available)
      fail(
        available
          ? `${ctx.customer.name} has ${rupees(available)} in advance. Use at most that much.`
          : `${ctx.customer.name} has no advance to use.`,
        409,
      );
    if (advance > ctx.total) fail("Use no more of the advance than the bill total.");
    for (const tender of ctx.tenders)
      if (tender.type === "Advance") {
        tender.confirmed = true;
        tender.reference = tender.reference || "Customer advance";
      }
    ctx.state.advanceApplied = advance;
  },
  beforePersist(ctx) {
    if (ctx.state.advanceApplied && ctx.invoice) ctx.invoice.advanceApplied = ctx.state.advanceApplied;
  },
  // Before the provider-confirmation rule: an advance is already held, nothing to confirm.
}, { before: "tender-rules" });
