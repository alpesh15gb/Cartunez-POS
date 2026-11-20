import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, putRecord } from "../db.js";
import { allow, scoped, integer, text, fail, id, now, audit, idempotent } from "../domain.js";

export function warrantyRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("warranty-claims", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const returned = await scoped(tx, actor, "return", body.returnId);
    if (returned.condition !== "warranty") fail("Choose a warranty return.");
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
  post("core-returns", async (tx, actor, body) => {
    return idempotent(tx, actor, body.transactionId, body, async () => {
      allow(actor, ["owner", "manager"]);
      const invoice = await scoped(tx, actor, "invoice", body.invoiceId);
      const originals = invoice.lines.filter(
        (line: any) => line.productId === body.productId && line.coreCharge > 0,
      );
      if (!originals.length)
        fail("This invoice has no core charge for that part.");
      const shift = (
        await records(tx, actor.organizationId, "shift", actor.branchId)
      ).find((item) => item.userId === actor.id && !item.closedAt);
      if (!shift) fail("Open your shift before recording a refund.", 409);
      const previous = (
        await records(tx, actor.organizationId, "coreReturn", actor.branchId)
      )
        .filter(
          (item) =>
            item.invoiceId === invoice.id && item.productId === body.productId,
        )
        .reduce((sum, item) => sum + item.quantity, 0);
      const quantity = integer(
        body.quantity,
        "Core return quantity",
        1,
        originals.reduce((sum: number, line: any) => sum + line.qty, 0) -
          previous,
      );
      if (!["Cash", "Card", "UPI", "Credit"].includes(body.refundType || "Cash"))
        fail("Choose a supported refund method.");
      if (body.refundType === "Credit" && !invoice.customerId)
        fail("Only a sale to a named customer can be refunded to their account.");
      const entry = {
        id: id("core"),
        branchId: actor.branchId,
        invoiceId: invoice.id,
        productId: body.productId,
        quantity,
        total: quantity * originals[0].coreCharge,
        reason: text(body.reason, "reason"),
        refundType: body.refundType || "Cash",
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
