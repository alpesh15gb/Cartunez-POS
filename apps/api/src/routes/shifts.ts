import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, putRecord } from "../db.js";
import { allow, scoped, integer, text, fail, id, now, audit, idempotent } from "../domain.js";
import { shiftCashSummaries, shiftSummary, countDenominations } from "../shift-cash.js";

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
    const shift = await scoped(db, actor, "shift", request.params.id);
    if (shift.userId !== actor.id) allow(actor, ["owner", "manager"]);
    return shiftSummary(db, actor, shift);
  });
  post("approvals", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    // WS-B: credit-limit (sell on credit above the limit), advance-refund (give an advance back).
    if (!["fitment", "discount", "return", "adjustment", "credit-limit", "advance-refund"].includes(body.action))
      fail("Unknown approval action.");
    const approval = {
      id: id("approval"),
      branchId: actor.branchId,
      action: body.action,
      transactionId: text(body.transactionId, "transaction ID"),
      reason: text(body.reason, "reason"),
      approvedBy: actor.id,
      used: false,
      expiresAt: new Date(Date.now() + 900000).toISOString(),
    };
    await audit(tx, actor, "approval", approval.id, approval.reason, {
      action: approval.action,
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
