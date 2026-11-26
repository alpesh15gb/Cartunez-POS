import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord } from "../src/db.js";
import { holdReserves } from "../src/domain.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

// WS-A: parked sales carry a label, the customer's name and the vehicle registration.
test("Holds: label, customer name, reg no and expiry; UPI ID setting", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db, {});
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({
        method: method as any,
        url: "/api/v1/" + path,
        payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const cart = {
      transactionId: "t-hold-1",
      priceLevel: "wholesale",
      customerId: "",
      vehicle: { make: "Maruti", model: "Swift", year: 2019 },
      lines: [{ productId: "filter", qty: 2, binId: "bin-a1", serials: [] }],
    };

    const hold = await call("holds", { cart, label: "Bay 2", customerName: "Ravi", regNo: "mh 12-ab 1234" }, cashier);
    assert.equal(hold.label, "Bay 2");
    assert.equal(hold.customerName, "Ravi");
    assert.equal(hold.regNo, "MH12AB1234");
    assert.equal(hold.expiresAt, null);
    assert.equal(hold.cart.priceLevel, "wholesale");
    assert.equal(hold.cart.vehicle.model, "Swift");

    // Re-parking keeps the label unless a new one is given.
    const again = await call("holds", { id: hold.id, cart: { ...cart, lines: [{ ...cart.lines[0], qty: 3 }] } }, cashier);
    assert.equal(again.id, hold.id);
    assert.equal(again.regNo, "MH12AB1234");
    assert.equal(again.label, "Bay 2");
    assert.equal(again.createdAt, hold.createdAt);

    const later = new Date(Date.now() + 3600 * 1000).toISOString();
    const expiring = await call("holds", { cart: { ...cart, transactionId: "t-hold-2" }, regNo: "KA01MJ0001", expiresAt: later }, cashier);
    assert.equal(expiring.expiresAt, later);

    await call("holds", { cart, regNo: "MH-12 / AB" }, cashier, 400);
    await call("holds", { cart, expiresAt: "2020-01-01T00:00:00Z" }, cashier, 400);
    await call("holds", { cart, label: "x".repeat(61) }, cashier, 400);

    const listed = (await call("bootstrap", undefined, cashier, 200, "GET")).holds;
    assert.deepEqual(listed.map((h: any) => h.regNo).sort(), ["KA01MJ0001", "MH12AB1234"]);

    assert.deepEqual(await call(`holds/${hold.id}`, undefined, cashier, 200, "DELETE"), { deleted: true });
    assert.equal((await call("bootstrap", undefined, cashier, 200, "GET")).holds.length, 1);

    // Integration: once a hold's expiry passes it stops reserving stock (it stays listed until discarded).
    const filterStock = async () =>
      (await call("bootstrap", undefined, cashier, 200, "GET")).stock.find((s: any) => s.productId === "filter" && s.binId === "bin-a1");
    const reservedBefore = await filterStock();
    assert.equal(reservedBefore.reserved, 2, "the expiring hold still reserves its 2 filters");
    const stored = (await getRecord(db, "demo", "hold", expiring.id))!;
    await putRecord(db, "demo", "hold", { ...stored, expiresAt: new Date(Date.now() - 60000).toISOString() }, stored.branchId);
    const released = await filterStock();
    assert.equal(released.reserved, 0);
    assert.equal(released.available, reservedBefore.available + 2);
    assert.equal((await call("bootstrap", undefined, cashier, 200, "GET")).holds.length, 1);
    assert.equal(holdReserves({ expiresAt: null }), true);
    assert.equal(holdReserves({ expiresAt: new Date(Date.now() - 1).toISOString() }), false);

    // The shop's UPI ID for the counter QR.
    await call("settings", { upiVpa: "cartunez@okhdfcbank", upiPayeeName: "Cartunez" }, cashier, 403);
    await call("settings", { upiVpa: "not a vpa" }, owner, 400);
    const settings = await call("settings", { upiVpa: "cartunez@okhdfcbank", upiPayeeName: "Cartunez" }, owner);
    assert.equal(settings.upiVpa, "cartunez@okhdfcbank");
    assert.equal((await call("bootstrap", undefined, cashier, 200, "GET")).settings.upiPayeeName, "Cartunez");
    await call("settings", { upiVpa: "" }, owner);
  } finally {
    await app.close();
    await db.close();
  }
});

test("negative stock cannot consume another hold's reservation", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db, {});
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({
        method: method as any,
        url: "/api/v1/" + path,
        payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const owner = (await call("auth/login", { email: "owner@motorline.local", password: "MotorlineDemo123!" })).token;
    const cashier = (await call("auth/login", { email: "cashier@motorline.local", password: "MotorlineDemo123!" })).token;
    await call("settings", { features: { negativeStock: true } }, owner);
    const waiting = await call("products", { name: "Ordered before first receipt", retailPrice: 100, taxRate: 0 }, owner);
    const waitingLine = { productId: waiting.id, binId: "bin-a1", qty: 1 };
    const firstClaim = await call("holds", { cart: { lines: [waitingLine] } }, cashier);
    await call("holds", { cart: { lines: [waitingLine] } }, owner, 409);
    const onOrder = (await call("bootstrap", undefined, owner, 200, "GET")).stock.find((row: any) => row.productId === waiting.id);
    assert.deepEqual([onOrder.quantity, onOrder.reserved, onOrder.available], [0, 1, -1]);
    await call(`holds/${firstClaim.id}`, undefined, cashier, 200, "DELETE");
    const part = await call("products", { name: "Reserved negative-stock part", retailPrice: 100, taxRate: 0 }, owner);
    await call("inventory/adjust", {
      transactionId: randomUUID(), productId: part.id, binId: "bin-a1", quantity: 1, reason: "Opening stock",
    }, owner);
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    const line = { productId: part.id, qty: 1, binId: "bin-a1" };
    const hold = await call("holds", { cart: { lines: [line] } }, cashier);
    const stock = async () => (await call("bootstrap", undefined, owner, 200, "GET")).stock
      .find((entry: any) => entry.productId === part.id && entry.binId === "bin-a1");
    assert.equal((await stock()).quantity, 1);
    assert.equal((await stock()).reserved, 1);
    assert.equal((await stock()).available, 0);
    const sale = (transactionId: string) => ({
      transactionId, shiftId: shift.id, lines: [line],
      tenders: [{ type: "Cash", amount: 1000, confirmed: true }],
    });
    const refused = await call("invoices", sale(randomUUID()), cashier, 409);
    assert.match(refused.error, /Insufficient stock/);
    assert.equal((await stock()).quantity, 1, "the held unit was not sold twice");
    await call("holds", { cart: { lines: [line] } }, owner, 409);
    await call("jobs", { customerId: "customer-1", lines: [line] }, owner, 409);
    const kit = await call("products", { name: "Reserved component kit", retailPrice: 100, taxRate: 0,
      components: [{ productId: part.id, qty: 1 }] }, owner);
    // The shortage can be booked in a different bin while the held unit stays available to its original bill.
    const kitLines = [{ productId: kit.id, qty: 1 }];
    const parkedKit = await call("holds", { cart: { lines: kitLines } }, owner);
    assert.notEqual(parkedKit.cart.lines[0].components[0].binId, "bin-a1");
    await call(`holds/${parkedKit.id}`, undefined, owner, 200, "DELETE");
    const soldKit = await call("invoices", { ...sale(randomUUID()), lines: kitLines }, cashier);
    assert.notEqual(soldKit.lines[0].components[0].binId, "bin-a1");
    assert.equal((await stock()).quantity, 1);
    // Once every sellable bin has a reserved physical unit, neither checkout nor parking may take one.
    for (const binId of ["bin-a2", "bin-b1"]) {
      const bin = (await call("bootstrap", undefined, owner, 200, "GET")).stock
        .find((entry: any) => entry.productId === part.id && entry.binId === binId);
      await call("inventory/adjust", { productId: part.id, binId, quantity: 1 - (bin?.quantity ?? 0), reason: "Stock received" }, owner);
      await call("holds", { cart: { lines: [{ ...line, binId }] } }, owner);
    }
    await call("invoices", { ...sale(randomUUID()), lines: kitLines }, cashier, 409);
    await call("holds", { cart: { lines: kitLines } }, cashier, 409);
    assert.equal((await stock()).quantity, 1);
    await call("inventory/adjust", {
      transactionId: randomUUID(), productId: part.id, binId: "bin-a1", quantity: 1, reason: "Opening stock",
    }, owner);
    assert.equal((await stock()).available, 1);
    await call("invoices", { ...sale(randomUUID()), lines: [{ ...line, qty: 2 }] }, cashier, 409);
    assert.equal((await stock()).quantity, 2, "negative stock cannot spill into the reserved unit");
    await call(`holds/${hold.id}`, undefined, cashier, 200, "DELETE");
    const sold = await call("invoices", { ...sale(randomUUID()), lines: [{ ...line, qty: 3 }] }, cashier);
    assert.ok(sold.id);
    assert.equal((await stock()).quantity, -1, "genuinely unreserved demand can still go negative");
    assert.equal((await stock()).reserved, 0);
    await call("inventory/adjust", { productId: part.id, binId: "bin-a1", quantity: 2, reason: "One unit available again" }, owner);
    await putRecord(db, "demo", "onlineOrder", { id: "reserved-for-website", branchId: "pune",
      lines: [{ productId: part.id, reserved: 1 }] }, "pune");
    assert.equal((await stock()).reserved, 1);
    await call("invoices", sale(randomUUID()), cashier, 409);
    await call("invoices", { ...sale(randomUUID()), lines: kitLines }, cashier, 409);
    assert.equal((await stock()).quantity, 1, "the online order still has its unit");

    const tracked = await call("products", { name: "Serial reserved for job", retailPrice: 100, serialTracked: true }, owner);
    await call("purchase-bills", { supplierId: "supplier-1", billNumber: randomUUID(), lines: [
      { productId: tracked.id, quantity: 2, binId: "bin-a1", cost: 25, serials: ["RES01", "FREE02"] }] }, owner);
    const trackedLine = { productId: tracked.id, binId: "bin-a1", qty: 1, serials: ["RES01"] };
    const trackedHold = await call("holds", { cart: { lines: [trackedLine] } }, owner);
    await call("holds", { cart: { lines: [trackedLine] } }, cashier, 409);
    await call("invoices", { ...sale(randomUUID()), lines: [trackedLine] }, cashier, 409);
    const freeSerial = await call("invoices", { ...sale(randomUUID()), lines: [{ ...trackedLine, serials: ["FREE02"] }] }, cashier);
    assert.deepEqual(freeSerial.lines[0].serials, ["FREE02"]);
    const ownSerial = await call("invoices", { ...sale(randomUUID()), holdId: trackedHold.id, lines: [trackedLine] }, cashier);
    assert.deepEqual(ownSerial.lines[0].serials, ["RES01"]);
  } finally {
    await app.close();
    await db.close();
  }
});
