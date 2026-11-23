import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, putRecord, getRecord } from "../db.js";
import { type Actor, allow, scoped, integer, text, fail, id, now, audit, idempotent, normalize } from "../domain.js";
import { shiftCashSummaries, shiftSummary, countDenominations } from "../shift-cash.js";

// Security: what each approval must be bound to.
const approvalRules: Record<string, { amount: boolean; amountLabel: string; subject: boolean; subjectLabel: string }> = {
  fitment: { amount: false, amountLabel: "", subject: false, subjectLabel: "" },
  discount: { amount: true, amountLabel: "largest discount", subject: false, subjectLabel: "customer" },
  return: { amount: false, amountLabel: "largest refund", subject: true, subjectLabel: "invoice number" },
  adjustment: { amount: false, amountLabel: "largest quantity", subject: false, subjectLabel: "part SKU" },
  "credit-limit": { amount: true, amountLabel: "most that may go on credit", subject: true, subjectLabel: "customer phone" },
  "advance-refund": { amount: true, amountLabel: "most that may be given back", subject: true, subjectLabel: "customer phone" },
};

/** The record an approval is for: an invoice (id or number), a customer (id or phone) or a part (id or SKU). */
async function approvalSubject(tx: Database, actor: Actor, action: string, value: string) {
  const key = normalize(value);
  if (action === "return") {
    const invoice = (await getRecord(tx, actor.organizationId, "invoice", value)) ||
      (await records(tx, actor.organizationId, "invoice", actor.branchId)).find((entry) => normalize(entry.number) === key);
    if (!invoice || invoice.branchId !== actor.branchId) fail(`No invoice ${value} in this branch.`, 404);
    return { id: invoice.id, label: String(invoice.number || invoice.id) };
  }
  if (action === "adjustment") {
    const product = (await getRecord(tx, actor.organizationId, "product", value)) ||
      (await records(tx, actor.organizationId, "product")).find((entry) => normalize(entry.sku) === key);
    if (!product) fail(`No part with SKU ${value}.`, 404);
    return { id: product.id, label: String(product.sku || product.name) };
  }
  if (action === "fitment") fail("A fitment approval is not tied to a customer or part.");
  const digits = value.replace(/\D/g, "");
  const customer = (await getRecord(tx, actor.organizationId, "customer", value)) ||
    (digits.length >= 6
      ? (await records(tx, actor.organizationId, "customer")).find((entry) => String(entry.phone || "").replace(/\D/g, "").endsWith(digits))
      : undefined);
  if (!customer) fail(`No customer with phone ${value}.`, 404);
  return { id: customer.id, label: String(customer.name || customer.phone) };
}

export function shiftRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("shifts/open", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "cashier"]);
    if (
      (await records(tx, actor.organizationId, "shift", actor.branchId)).some(
        (shift) => shift.userId === actor.id && !shift.closedAt,
      )
    )
      fail("You already have an open shift.", 409);
    const shift = {
      id: id("shift"),
      branchId: actor.branchId,
      userId: actor.id,
      openedAt: now(),
      openingCash: integer(body.openingCash ?? 0, "Opening cash"),
    };
    return putRecord(tx, actor.organizationId, "shift", shift, actor.branchId);
  });
  post("shifts/:id/cash-movements", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "cashier"]);
    const shift = await scoped(tx, actor, "shift", params.id);
    if (shift.userId !== actor.id) fail("Record cash movements on your own shift.", 403);
    if (!["in", "out"].includes(body.direction)) fail("Choose cash in or cash out.");
    const amount = integer(body.amount, "Cash movement", 1);
    const reason = text(body.reason, "cash movement reason");
    const entry = { branchId: actor.branchId, shiftId: shift.id, userId: actor.id, direction: body.direction, amount, reason };
    return idempotent(tx, actor, body.transactionId, { operation: "cash-movement", ...entry }, async () => {
      if (shift.closedAt) fail("The shift has already closed.", 409);
      const movement = await putRecord(tx, actor.organizationId, "cashMovement", {
        id: id("cash"), ...entry, createdAt: now(),
      }, actor.branchId);
      await audit(tx, actor, "cash-" + body.direction, movement.id, reason, { shiftId: shift.id, amount });
      return movement;
    });
  });
  post("shifts/:id/close", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "cashier"]);
    const shift = await scoped(tx, actor, "shift", params.id);
    if (shift.userId !== actor.id) allow(actor, ["owner", "manager"]);
    if (shift.closedAt) fail("Shift already closed.", 409);
    const [summary] = await shiftCashSummaries(tx, actor, [shift]);
    if (body.reviewedExpectedCash !== undefined &&
        integer(body.reviewedExpectedCash, "Reviewed expected cash", -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER) !== summary.expectedCash)
      fail("Drawer activity changed. Review the updated expected cash before closing.", 409);
    shift.expectedCash = summary.expectedCash;
    // WS-D: optional note-by-note count; when given it must add up to the counted cash.
    const count = countDenominations(body.denominations);
    shift.countedCash = integer(body.countedCash ?? count?.total, "Counted cash");
    if (count && count.total !== shift.countedCash)
      fail("The note count does not add up to the counted cash.");
    if (count) shift.denominations = count.counts;
    shift.variance = shift.countedCash - shift.expectedCash;
    shift.closedAt = now();
    shift.reason = text(body.reason || "Shift close", "reason");
    await audit(tx, actor, "shift-close", shift.id, shift.reason, {
      variance: shift.variance,
    });
    return putRecord(tx, actor.organizationId, "shift", shift, actor.branchId);
  });
  // WS-D: shift summary (sales by tender, refunds, drawer movements, cash party payments, expected/counted).
  app.get("/api/v1/shifts/:id/summary", async (request: any) => {
    const actor = request.actor;
    allow(actor, ["owner", "manager", "cashier"]);
    return db.readSnapshot(async snapshot => {
      const shift = await scoped(snapshot, actor, "shift", request.params.id);
      if (shift.userId !== actor.id) allow(actor, ["owner", "manager"]);
      return shiftSummary(snapshot, actor, shift);
    });
  });
  post("approvals", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    // WS-B: credit-limit (sell on credit above the limit), advance-refund (give an advance back).
    if (!["fitment", "discount", "return", "adjustment", "credit-limit", "advance-refund"].includes(body.action))
      fail("Unknown approval action.");
    // Security: an approval is bound to what it approves — the most it covers
    // (paise; units for a stock adjustment) and the invoice / customer / part.
    const rule = approvalRules[body.action as string];
    const amount =
      body.amount === undefined || body.amount === null || body.amount === ""
        ? rule.amount
          ? fail(`Enter the ${rule.amountLabel} this approval covers.`)
          : null
        : integer(body.amount, rule.amountLabel || "Amount", 0, 100000000000);
    const subjectText = String(body.subjectId ?? body.subject ?? "").trim();
    const subject = subjectText
      ? await approvalSubject(tx, actor, body.action, subjectText)
      : rule.subject
        ? fail(`Enter the ${rule.subjectLabel} this approval is for.`)
        : null;
    const approval = {
      id: id("approval"),
      branchId: actor.branchId,
      action: body.action,
      transactionId: text(body.transactionId, "transaction ID"),
      reason: text(body.reason, "reason"),
      amount,
      subjectId: subject?.id ?? null,
      subjectLabel: subject?.label ?? null,
      approvedBy: actor.id,
      used: false,
      expiresAt: new Date(Date.now() + 900000).toISOString(),
    };
    await audit(tx, actor, "approval", approval.id, approval.reason, {
      action: approval.action,
      amount: approval.amount,
      subjectId: approval.subjectId,
    });
    return putRecord(
      tx,
      actor.organizationId,
      "approval",
      approval,
      actor.branchId,
    );
  });
}
