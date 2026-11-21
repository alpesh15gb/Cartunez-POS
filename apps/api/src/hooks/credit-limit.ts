// WS-B: Customer credit limit on the "Credit" (udhaar) tender.
//
// When a customer has a credit limit (customer.creditLimit, paise; set by an
// owner or manager) and this sale would take what they owe above it, the sale
// needs a manager: managers and owners pass; a cashier sends
// `creditApprovalId`, a "credit-limit" approval for this sale's transaction ID.
import { approved, audit, fail } from "../domain.js";
import { registerSaleHook } from "../sale-pipeline.js";
import { creditLimitOf, customerLedger, rupees } from "../customer-account.js";

registerSaleHook({
  name: "ws-b-credit-limit",
  async validateTenders(ctx) {
    const credit = ctx.tenders.filter((t) => t.type === "Credit").reduce((sum, t) => sum + t.amount, 0);
    if (!credit || !ctx.customer) return;
    const limit = creditLimitOf(ctx.customer);
    if (limit === null) return;
    const { balance } = await customerLedger(ctx.db, ctx.actor.organizationId, ctx.customer.id);
    const after = balance + credit;
    if (after <= limit) return;
    const manager = ["owner", "manager"].includes(ctx.actor.role);
    if (!manager && !ctx.body.creditApprovalId)
      fail(
        `${ctx.customer.name} would owe ${rupees(after)}, above their credit limit of ${rupees(limit)}. ` +
          `Take more of the payment now, or ask a manager to approve (reference ${ctx.body.transactionId}).`,
        403,
      );
    await approved(ctx.db, ctx.actor, "credit-limit", ctx.body.creditApprovalId, ctx.body.transactionId);
    ctx.state.creditLimitOverride = { limit, balanceBefore: balance, balanceAfter: after, approvalId: ctx.body.creditApprovalId || null };
  },
  beforePersist(ctx) {
    if (ctx.state.creditLimitOverride && ctx.invoice) ctx.invoice.creditLimitOverride = ctx.state.creditLimitOverride;
  },
  async afterPersist(ctx) {
    const override = ctx.state.creditLimitOverride;
    if (override)
      await audit(ctx.db, ctx.actor, "credit-limit-override", ctx.invoice!.id,
        `Sold on credit above the limit of ${rupees(override.limit)}`, override);
  },
});
