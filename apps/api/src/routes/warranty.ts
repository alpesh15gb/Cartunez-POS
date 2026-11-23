import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, putRecord } from "../db.js";
import { type Actor, allow, scoped, integer, text, fail, id, now, audit, idempotent } from "../domain.js";
import { checkAccountRefund, refundBreakdown, refundTypeOf, REFUND_TYPES } from "../returns.js";

async function coreRefund(db: Database, actor: Actor, body: any) {
  allow(actor, ["owner", "manager"]);
  const invoice = await scoped(db, actor, "invoice", text(body.invoiceId, "invoice"));
  const lines = invoice.lines.filter((line: any) => line.productId === body.productId && line.coreCharge > 0);
  if (!lines.length) fail("This invoice has no core charge for that part.");
  const previous = (await records(db, actor.organizationId, "coreReturn", actor.branchId)).filter(r => r.invoiceId === invoice.id);
  let skip = previous.filter(r => r.productId === body.productId).reduce((n, r) => n + r.quantity, 0);
  const unitsLeft = lines.reduce((n: number, l: any) => n + l.qty, 0) - skip;
  if (unitsLeft <= 0) fail("This part's core deposit was already refunded.");
  const quantity = integer(body.quantity, "Core return quantity", 1, unitsLeft);
  let remaining = quantity, total = 0;
  for (const line of lines) {
    const already = Math.min(skip, line.qty);
    skip -= already;
    const units = Math.min(remaining, line.qty - already);
    total += units * line.coreCharge;
    remaining -= units;
  }
  const method = body.refundType || "";
  if (method && !REFUND_TYPES.includes(method)) fail("Choose a supported refund method.");
  // Deposits occupy the final part of the invoice's original tender allocation. Line returns use the first part.
  const deposits = invoice.lines.reduce((n: number, l: any) => n + (l.coreCharge || 0) * l.qty, 0);
  const offset = invoice.total - deposits + previous.reduce((n, r) => n + r.total, 0);
  const refunds = refundBreakdown(invoice, offset, total, method);
  checkAccountRefund(invoice, refunds);
  return { invoiceId: invoice.id, productId: body.productId, currency: invoice.currency,
    quantity, total, refunds, refundType: refundTypeOf(refunds, method || "Cash") };
}

export function warrantyRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("warranty-claims", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const returned = await scoped(tx, actor, "return", body.returnId);
    // WS-B: a return can send some lines to the warranty bin (disposition "rma").
    if (returned.condition !== "warranty" && !(returned.lines || []).some((line: any) => line.disposition === "rma"))
      fail("Choose a warranty return.");
    await scoped(tx, actor, "supplier", body.supplierId);
    const previous = body.id
      ? await scoped(tx, actor, "warranty", body.id)
      : undefined;
    const claim = {
      ...previous,
      id: previous?.id || id("warranty"),
      branchId: actor.branchId,
      returnId: returned.id,
      supplierId: body.supplierId,
      reason: text(body.reason, "claim reason"),
      status: body.status || "open",
      createdAt: previous?.createdAt || now(),
      updatedAt: now(),
    };
    if (
      !["open", "sent", "approved", "rejected", "settled"].includes(
        claim.status,
      )
    )
      fail("Unknown warranty status.");
    await audit(tx, actor, "warranty", claim.id, claim.reason, {
      status: claim.status,
    });
    return putRecord(
      tx,
      actor.organizationId,
      "warranty",
      claim,
      actor.branchId,
    );
  });
  app.post("/api/v1/core-returns/preview", async (request: any) =>
    db.readSnapshot(snapshot => coreRefund(snapshot, request.actor, request.body ?? {})));
  post("core-returns", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    return idempotent(tx, actor, body.transactionId, body, async () => {
      const quote = await coreRefund(tx, actor, body);
      if (body.reviewedRefunds !== undefined) {
        const reviewed = body.reviewedRefunds;
        if (!Array.isArray(reviewed) || reviewed.length !== quote.refunds.length ||
            !quote.refunds.every((part, i) => part.type === reviewed[i]?.type && part.amount === reviewed[i]?.amount))
          fail("The refund allocation changed. Reopen the preview before recording this core return.", 409);
      }
      const shift = (
        await records(tx, actor.organizationId, "shift", actor.branchId)
      ).find((item) => item.userId === actor.id && !item.closedAt);
      if (!shift) fail("Open your shift before recording a refund.", 409);
      const entry = {
        id: id("core"),
        branchId: actor.branchId,
        ...quote,
        reason: text(body.reason, "reason"),
        createdAt: now(),
        userId: actor.id,
        shiftId: shift.id,
      };
      await audit(tx, actor, "core-return", entry.id, entry.reason);
      return putRecord(
        tx,
        actor.organizationId,
        "coreReturn",
        entry,
        actor.branchId,
      );
    });
  });
}
