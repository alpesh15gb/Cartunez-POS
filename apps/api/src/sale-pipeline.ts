// Checkout extension points. finalizeSale (sales.ts) runs these hooks in order
// at each stage; new checkout features add a hook here (or register one from
// their own module) instead of editing finalizeSale.
import { getRecord, putRecord } from "./db.js";
import { adjust, audit, fail, scoped, text } from "./domain.js";
import type { SaleContext, SaleHook, SaleLineInput, SaleLine } from "./sale-types.js";
import { ACCOUNT_TENDERS, DRAWER_TENDERS } from "./sale-types.js";

/** Rejects account tenders (e.g. Advance) that no hook has enabled. */
const accountTenderGate: SaleHook = {
  name: "account-tender-gate",
  validateTenders(ctx) {
    const enabled = acceptedAccountTenders();
    for (const tender of ctx.tenders)
      if ((ACCOUNT_TENDERS as readonly string[]).includes(tender.type) && !enabled.has(tender.type))
        fail(
          tender.type === "Advance"
            ? "Paying from a customer advance is not available yet. Take the payment by another method."
            : "This payment type is not available.",
        );
  },
};

/** Records who sold or fitted a line, when the register sends it. */
const staffOnLine: SaleHook = {
  name: "line-staff",
  async validateLine(ctx, input, line) {
    if (input.staffId === undefined || input.staffId === null || input.staffId === "") return;
    const staffId = text(input.staffId, "staff member", true, 200);
    const user = await getRecord(ctx.db, ctx.actor.organizationId, "user", staffId);
    if (!user || user.active === false) fail("Choose a staff member from this shop.");
    line.staffId = staffId;
  },
};

/** "Credit" = sold on the customer's account (udhaar); always available for a named customer, not drawer money. */
const creditTender: SaleHook = {
  name: "credit-tender",
  tenderTypes: ["Credit"],
  validateTenders(ctx) {
    const credit = ctx.tenders
      .filter((tender) => tender.type === "Credit")
      .reduce((sum, tender) => sum + tender.amount, 0);
    if (!credit) return;
    if (!ctx.body.customerId) fail("Choose the customer before selling on credit.");
    if (ctx.body.offline) fail("Credit sales need a connection to the server.", 403);
    for (const tender of ctx.tenders) if (tender.type === "Credit") tender.confirmed = true;
  },
};

/** Settings-enabled drawer tenders, external references, provider confirmation. */
const tenderRules: SaleHook = {
  name: "tender-rules",
  validateTenders(ctx) {
    const account = acceptedAccountTenders();
    const tenders = ctx.tenders;
    if (
      tenders.some(
        (tender) =>
          !account.has(tender.type) &&
          !(ctx.currentSettings.tenderTypes || DRAWER_TENDERS).includes(tender.type),
      )
    )
      fail("This payment type is disabled in Settings.");
    if (
      tenders.some(
        (tender) => tender.type !== "Cash" && !account.has(tender.type) && tender.confirmed && !tender.reference,
      )
    )
      fail("Record the external payment confirmation reference.");
    if (
      tenders.some(
        (tender) => !(DRAWER_TENDERS as readonly string[]).includes(tender.type) && !account.has(tender.type),
      )
    )
      fail("Unsupported tender type.");
    if (tenders.some((tender) => tender.type !== "Cash" && !tender.confirmed))
      fail("Provider-confirmed payments must remain pending until confirmation.", 409);
  },
};

/** Re-checks the customer is still in this branch's scope just before writing. */
const customerCheck: SaleHook = {
  name: "customer-check",
  async beforePersist(ctx) {
    if (ctx.body.customerId) await scoped(ctx.db, ctx.actor, "customer", ctx.body.customerId);
  },
};

/** Takes sold stock out of its bin and marks serials sold. */
const stockAndSerials: SaleHook = {
  name: "stock-and-serials",
  async afterPersist(ctx) {
    const { db, actor, invoice } = ctx;
    for (const line of ctx.lines) {
      // Services and online-only lines (ordered from the supplier) move no stock.
      if (line.type !== "service" && !line.onlineOnly)
        await adjust(
          db,
          actor,
          line.productId,
          line.binId,
          -line.qty,
          "Sale",
          invoice!.id,
          ctx.reconcile || (ctx.sellBeyondStock && !line.serials?.length),
        );
      for (const serial of line.serials)
        await putRecord(
          db,
          actor.organizationId,
          "serial",
          {
            id: line.productId + ":" + serial,
            branchId: actor.branchId,
            productId: line.productId,
            serial,
            binId: line.binId,
            status: "sold",
            invoiceId: invoice!.id,
          },
          actor.branchId,
        );
    }
  },
};

/** A held cart that was checked out is released. */
const releaseHold: SaleHook = {
  name: "release-hold",
  async afterPersist(ctx) {
    if (ctx.hold)
      await ctx.db.query(
        "DELETE FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3",
        [ctx.actor.organizationId, "hold", ctx.hold.id],
      );
  },
};

const saleAudit: SaleHook = {
  name: "audit",
  async afterPersist(ctx) {
    await audit(ctx.db, ctx.actor, "sale", ctx.invoice!.id, ctx.body.discountReason || "Checkout", {
      total: ctx.total,
      override: ctx.requiresFitmentApproval,
      reconciled: ctx.reconcile,
    });
  },
};

const hooks: SaleHook[] = [
  accountTenderGate,
  staffOnLine,
  creditTender,
  tenderRules,
  customerCheck,
  stockAndSerials,
  releaseHold,
  saleAudit,
];

/**
 * Adds a checkout hook. By default it runs after every hook already registered
 * (built-ins included); pass `before` with a hook name to run ahead of it
 * (e.g. `{ before: "audit" }`). Returns a function that removes the hook.
 */
export function registerSaleHook(hook: SaleHook, options: { before?: string } = {}) {
  if (hooks.some((existing) => existing.name === hook.name))
    throw new Error(`Sale hook "${hook.name}" is already registered.`);
  const at = options.before ? hooks.findIndex((existing) => existing.name === options.before) : -1;
  if (options.before && at < 0) throw new Error(`Sale hook "${options.before}" is not registered.`);
  hooks.splice(at < 0 ? hooks.length : at, 0, hook);
  return () => {
    const index = hooks.indexOf(hook);
    if (index >= 0) hooks.splice(index, 1);
  };
}

export function saleHooks(): readonly SaleHook[] {
  return hooks;
}

/** Account-style tender types some registered hook accepts. */
export function acceptedAccountTenders() {
  return new Set(hooks.flatMap((hook) => hook.tenderTypes || []));
}

type Stage = "expandLines" | "validateTenders" | "beforePersist" | "afterPersist";
export async function runStage(stage: Stage, ctx: SaleContext) {
  for (const hook of [...hooks]) await hook[stage]?.(ctx);
}
export async function runValidateLine(ctx: SaleContext, input: SaleLineInput, line: SaleLine) {
  for (const hook of [...hooks]) await hook.validateLine?.(ctx, input, line);
}
