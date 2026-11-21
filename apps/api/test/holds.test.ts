import { test } from "node:test";
import assert from "node:assert/strict";
import { connectDatabase, migrate } from "../src/db.js";
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
