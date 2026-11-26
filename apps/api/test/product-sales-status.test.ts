import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createApp } from "../src/app.js";
import { connectDatabase, migrate, records } from "../src/db.js";
import { seed } from "../src/seed.js";

test("managers can stop and resume a traded part across the register, offline claims, stock and Magento", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    const login = async (role: string) => (await app.inject({ method: "POST", url: "/api/v1/auth/login",
      payload: { email: role + "@motorline.local", password: "MotorlineDemo123!" } })).json().token;
    const owner = await login("owner");
    const inventory = await login("inventory");
    const manager = await login("manager");
    const call = async (path: string, body?: any, expected = 200, token = owner) => {
      const reply = await app.inject({ method: body ? "POST" : "GET", url: "/api/v1/" + path,
        payload: body, headers: { authorization: "Bearer " + token } });
      assert.equal(reply.statusCode, expected, reply.body);
      return reply.json();
    };
    const part = await call("products", { sku: "TRADED01", name: "Trading part", brand: "Test", category: "Parts",
      unit: "Each", retailPrice: 100, wholesalePrice: 100, taxRate: 0, reorderLevel: 5, universal: true });
    const toggle = (salesAction: string, status = 200, token = manager) =>
      call("products", { id: part.id, salesAction }, status, token);
    const listing = (published: boolean, status = 200) =>
      call("online-listings", { productIds: [part.id], changes: { published } }, status);
    await call("inventory/adjust", { productId: part.id, binId: "bin-a1", quantity: 4, reason: "Opening stock" });
    const shift = await call("shifts/open", { openingCash: 1000 });
    const sale = { transactionId: randomUUID(), shiftId: shift.id, lines: [{ productId: part.id, qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 100, confirmed: true }] };
    const invoice = await call("invoices", sale);
    const device = await call("devices/enroll", { name: "Counter 1", offlineAllowed: true, offlineHours: 24, tenders: ["Cash"], rangeSize: 1000 });
    const trackedLater = await call("products", { sku: "TRACK-LATER", name: "Tracking changes later", retailPrice: 100,
      wholesalePrice: 100, taxRate: 0, universal: true });
    const kit = await call("products", { name: "Tracking test kit", retailPrice: 100, taxRate: 0,
      components: [{ productId: trackedLater.id, qty: 1 }] });
    const before = await call("bootstrap");
    const offline = { ...sale, transactionId: randomUUID(), invoiceNumber: device.rangeStart,
      deviceId: device.id, offline: true, occurredAt: new Date().toISOString(), catalogRevision: before.catalogRevision };
    const sync = async (claim: any) => (await call("sync", { deviceId: device.id, transactions: [claim] })).results[0];
    const accepted = await sync(offline);
    assert.equal(accepted.status, "accepted");
    const directOffline = await call("invoices", offline, 403);
    assert.match(directOffline.error, /sync route/i);
    await call("products", { ...trackedLater, serialTracked: true });
    const trackingClaim = {
      ...offline, transactionId: randomUUID(), invoiceNumber: device.rangeStart + 3,
      lines: [{ productId: trackedLater.id, qty: 1, binId: "bin-a1" }],
    };
    const trackingConflict = await sync(trackingClaim);
    assert.equal(trackingConflict.status, "conflict");
    assert.match(trackingConflict.error, /serial tracking/i);
    assert.equal((await records(db, "demo", "invoice")).some((invoice) => invoice.transactionId === trackingClaim.transactionId), false);
    const kitClaim = { ...offline, transactionId: randomUUID(), invoiceNumber: device.rangeStart + 4, lines: [{ productId: kit.id, qty: 1 }] };
    const kitConflict = await sync(kitClaim);
    assert.equal(kitConflict.status, "conflict");
    assert.match(kitConflict.error, /serial tracking/i);
    await call("products", { ...kit, components: [{ productId: "filter", qty: 1 }] });
    const changedKit = await sync({ ...kitClaim, transactionId: randomUUID(), invoiceNumber: device.rangeStart + 5 });
    assert.equal(changedKit.status, "conflict");
    assert.match(changedKit.error, /kit components/i);
    await listing(true);
    await toggle("stop", 409);
    await listing(false);
    await toggle("stop", 403, inventory);
    const parked = await call("holds", { cart: { lines: sale.lines } });
    await toggle("stop", 409);
    const release = await app.inject({ method: "DELETE", url: "/api/v1/holds/" + parked.id, headers: { authorization: "Bearer " + owner } });
    assert.equal(release.statusCode, 200, release.body);
    assert.equal((await toggle("stop")).salesStopped, true);
    // An older inventory client saves its original copy of the product.
    assert.equal((await call("products", { ...part, salesStopped: false, description: "Shelf 1" }, 200, inventory)).salesStopped, true);
    await listing(true, 409);
    await call("holds", { cart: { lines: sale.lines } }, 409);
    await call("invoices", { ...sale, transactionId: randomUUID() }, 409);
    assert.equal((await call("invoices", sale)).id, invoice.id);
    assert.equal((await sync(offline)).invoice.id, accepted.invoice.id);
    const late = { ...offline, transactionId: randomUUID(), invoiceNumber: device.rangeStart + 1 };
    const conflict = await sync(late);
    assert.equal(conflict.status, "conflict");
    assert.match(conflict.error, /sales are stopped/i);
    assert.equal((await sync(late)).conflictId, conflict.conflictId);
    const stopped = await call("bootstrap");
    assert.equal(stopped.products.find((p: any) => p.id === part.id).salesStopped, true);
    assert.equal(stopped.reorderSuggestions.some((p: any) => p.productId === part.id), false);
    assert.equal(stopped.stock.find((p: any) => p.productId === part.id).quantity, 2);
    const returned = await call("invoices/" + invoice.id + "/returns", { transactionId: randomUUID(), reason: "Shelf return",
      condition: "sellable", lines: [{ lineId: invoice.lines[0].id, quantity: 1, binId: "bin-a1" }], refundType: "Cash" });
    assert.equal(returned.total, 100);
    const report = await call("reports/sales?sku=TRADED01");
    assert.equal(report.totals.gross, 200);
    assert.equal(report.totals.returns, 100);
    const resumed = await toggle("resume");
    assert.ok(!resumed.salesStopped);
    const after = await call("bootstrap");
    assert.equal(after.stock.find((p: any) => p.productId === part.id).quantity, 3);
    assert.ok(after.reorderSuggestions.some((p: any) => p.productId === part.id));
    const badSnapshot = await sync({ ...late, transactionId: randomUUID(), invoiceNumber: device.rangeStart + 2,
      catalogRevision: stopped.catalogRevision });
    assert.equal(badSnapshot.status, "conflict");
    assert.match(badSnapshot.error, /sales are stopped/i);
    assert.equal((await call("conflicts/" + conflict.conflictId + "/resolve", {
      action: "accept", reason: "Verified earlier offline payment after resuming sales" })).status, "accepted");
    await call("invoices", { ...sale, transactionId: randomUUID() });
    await listing(true);
    const audit = (await records(db, "demo", "audit")).filter((a) => a.subject === part.id);
    for (const reason of ["Stopped new sales", "Resumed sales"]) assert.ok(audit.some((a) => a.reason === reason));
  } finally {
    await app.close();
    await db.close();
  }
});
