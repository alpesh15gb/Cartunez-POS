import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, getRecord, putRecord } from "../db.js";
import { type Actor, allow, scoped, integer, text, fail, id, now, audit, idempotent } from "../domain.js";
import { finalizeSale } from "../sales.js";

export function deviceRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("devices/enroll", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    const rangeSize = integer(
      body.rangeSize || 1000,
      "Invoice range size",
      10,
      100000,
    );
    const hours = integer(
      body.offlineHours ?? settings.offlineHours,
      "Offline hours",
      0,
      settings.offlineHours,
    );
    const tenders = body.tenders || settings.offlineTenders;
    if (
      !Array.isArray(tenders) ||
      tenders.some((tender: any) => !settings.offlineTenders.includes(tender))
    )
      fail("Offline tenders exceed organization policy.");
    const device = {
      id: id("device"),
      branchId: actor.branchId,
      name: text(body.name, "device name"),
      offlineAllowed: body.offlineAllowed === true,
      offlineUntil: new Date(Date.now() + hours * 3600000).toISOString(),
      enrolledAt: now(),
      enrolledBy: actor.id,
      tenders,
      rangeStart: settings.nextDeviceNumber,
      rangeEnd: settings.nextDeviceNumber + rangeSize - 1,
      nextNumber: settings.nextDeviceNumber,
    };
    settings.nextDeviceNumber += rangeSize;
    await putRecord(tx, actor.organizationId, "settings", settings);
    await audit(
      tx,
      actor,
      "device-enrollment",
      device.id,
      "Offline enrollment",
      device,
    );
    return putRecord(
      tx,
      actor.organizationId,
      "device",
      device,
      actor.branchId,
    );
  });
  post("devices/:id", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const device = await scoped(tx, actor, "device", params.id);
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    if (body.offlineAllowed !== undefined)
      device.offlineAllowed = body.offlineAllowed === true;
    if (body.renewHours !== undefined)
      device.offlineUntil = new Date(
        Date.now() +
          integer(body.renewHours, "Renew hours", 1, settings.offlineHours) *
            3600000,
      ).toISOString();
    await audit(
      tx,
      actor,
      "device-policy",
      device.id,
      text(body.reason, "reason"),
      body,
    );
    return putRecord(
      tx,
      actor.organizationId,
      "device",
      device,
      actor.branchId,
    );
  });
  app.post("/api/v1/sync", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager", "cashier"]);
    const body = request.body;
    if (!Array.isArray(body.transactions) || body.transactions.length > 100)
      fail("Synchronize up to 100 transactions.");
    const results = [];
    for (const input of body.transactions) {
      const sale = { ...input, deviceId: body.deviceId, offline: true };
      const existing = (
        await records(db, actor.organizationId, "conflict", actor.branchId)
      ).find((item) => item.transactionId === sale.transactionId);
      if (existing) {
        results.push({
          transactionId: sale.transactionId,
          status: existing.status === "pending" ? "conflict" : existing.status,
          invoice: existing.invoice,
          conflictId: existing.id,
          error: existing.error,
        });
        continue;
      }
      try {
        const invoice = await db.transaction((tx) =>
          idempotent(tx, actor, sale.transactionId, sale, () =>
            finalizeSale(tx, actor, sale),
          ),
        );
        results.push({
          transactionId: sale.transactionId,
          status: "accepted",
          invoice,
        });
      } catch (error: any) {
        const conflict = await db.transaction(async (tx) => {
          const found = (
            await records(tx, actor.organizationId, "conflict", actor.branchId)
          ).find((item) => item.transactionId === sale.transactionId);
          if (found) return found;
          const item = {
            id: id("conflict"),
            branchId: actor.branchId,
            transactionId: sale.transactionId,
            actor,
            sale,
            status: "pending",
            error: error.message,
            createdAt: now(),
          };
          await audit(tx, actor, "sync-conflict", item.id, error.message);
          return putRecord(
            tx,
            actor.organizationId,
            "conflict",
            item,
            actor.branchId,
          );
        });
        results.push({
          transactionId: sale.transactionId,
          status: "conflict",
          conflictId: conflict.id,
          error: error.message,
        });
      }
    }
    return { results, serverTime: now() };
  });
  post("conflicts/:id/resolve", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const conflict = await scoped(tx, actor, "conflict", params.id);
    if (conflict.status !== "pending") return conflict;
    text(body.reason, "reconciliation reason");
    if (!["accept", "reject"].includes(body.action))
      fail("Choose accept or reject.");
    if (body.action === "accept")
      conflict.invoice = await idempotent(
        tx,
        actor,
        conflict.sale.transactionId,
        conflict.sale,
        () =>
          finalizeSale(
            tx,
            { ...conflict.actor, role: actor.role },
            conflict.sale,
            true,
          ),
      );
    conflict.status = body.action === "accept" ? "accepted" : "rejected";
    conflict.refundRequired = body.action === "reject";
    conflict.resolvedBy = actor.id;
    conflict.reason = body.reason;
    conflict.resolvedAt = now();
    await audit(tx, actor, "conflict-resolution", conflict.id, body.reason, {
      action: body.action,
      refundRequired: conflict.refundRequired,
    });
    return putRecord(
      tx,
      actor.organizationId,
      "conflict",
      conflict,
      actor.branchId,
    );
  });
}
