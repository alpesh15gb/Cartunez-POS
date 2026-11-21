// WS-D: PIN sign-in on enrolled counters, lockout, and the shift summary / note count.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

async function setup() {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  async function call(path: string, token: string, body?: any, status = 200) {
    const response = await app.inject({
      method: body === undefined ? "GET" : "POST", url: "/api/v1/" + path, payload: body,
      headers: token ? { authorization: "Bearer " + token } : {},
    });
    assert.equal(response.statusCode, status, path + ": " + response.body);
    return { json: response.json(), body: response.body };
  }
  const login = async (role: string, branchId = "pune") => (await call("auth/login", "", {
    email: role + "@motorline.local", password: "MotorlineDemo123!", branchId,
  })).json.token;
  return { db, app, call, login };
}

test("PIN sign-in works only on an enrolled PIN counter of the staff member's branch and never leaks the hash", async () => {
  const { db, app, call, login } = await setup();
  try {
    const owner = await login("owner");
    const manager = await login("manager");
    const cashier = await login("cashier");
    const cashierId = "user-cashier";

    // Setting PINs: owner/manager only, 4–6 digits, not trivial, owners excluded.
    await call(`users/${cashierId}/pin`, cashier, { pin: "4826" }, 403);
    for (const pin of ["12", "1234567", "12a4", "1111", "1234", 4826])
      await call(`users/${cashierId}/pin`, manager, { pin }, 400);
    await call("users/user-owner/pin", owner, { pin: "4826" }, 400);
    const set = await call(`users/${cashierId}/pin`, manager, { pin: "4826" });
    assert.equal(set.json.hasPin, true);
    assert.ok(!set.body.includes("pinHash") && !set.body.includes("passwordHash"));
    // Security: no uniqueness check (it revealed other people's PINs); the counter picks the person first.

    // The hash is never returned: bootstrap (owner and manager), password login, user edit.
    for (const token of [owner, manager, cashier]) {
      const boot = await call("bootstrap", token);
      assert.ok(!boot.body.includes("pinHash"), "bootstrap leaks pinHash");
      assert.ok(!boot.body.includes("passwordHash"));
    }
    const managerBoot = (await call("bootstrap", manager)).json;
    assert.equal(managerBoot.users.find((u: any) => u.id === cashierId).hasPin, true);
    const passwordLogin = await call("auth/login", "", { email: "cashier@motorline.local", password: "MotorlineDemo123!", branchId: "pune" });
    assert.ok(!passwordLogin.body.includes("pinHash"));
    const ownerBoot = (await call("bootstrap", owner)).json;
    const cashierRecord = ownerBoot.users.find((u: any) => u.id === cashierId);
    const edited = await call("users", owner, { ...cashierRecord, name: "Counter Cashier" });
    assert.ok(!edited.body.includes("pinHash"));
    assert.equal(edited.json.hasPin, true, "editing the user keeps the PIN");

    // Without an enrolled PIN counter nobody signs in by PIN.
    await call("auth/pin-login", "", { deviceId: "device-x", deviceKey: "nope", userId: cashierId, pin: "4826" }, 401);
    const device = (await call("devices/enroll", manager, { name: "Front counter" })).json;
    await call(`devices/${device.id}/pin-key`, await login("cashier"), {}, 403); // the edit signed the cashier out
    const enrolled = (await call(`devices/${device.id}/pin-key`, manager, {})).json;
    assert.ok(enrolled.key.length >= 40);
    const otherBranchOwner = await login("owner", "mumbai");
    await call(`devices/${device.id}/pin-key`, otherBranchOwner, {}, 404);
    const deviceBody = { deviceId: device.id, deviceKey: enrolled.key };
    assert.ok(!JSON.stringify((await call("bootstrap", owner)).json).includes(enrolled.key), "device key is not in bootstrap");

    const tiles = (await call("auth/pin-staff", "", deviceBody)).json;
    assert.deepEqual(tiles.staff.map((s: any) => s.id), [cashierId]);
    assert.equal(tiles.branchId, "pune");
    await call("auth/pin-staff", "", { ...deviceBody, deviceKey: enrolled.key + "x" }, 401);

    const signedIn = await call("auth/pin-login", "", { ...deviceBody, userId: cashierId, pin: "4826" });
    assert.equal(signedIn.json.branchId, "pune");
    assert.equal(signedIn.json.user.id, cashierId);
    assert.ok(!signedIn.body.includes("pinHash") && !signedIn.body.includes("passwordHash"));
    const boot = (await call("bootstrap", signedIn.json.token)).json;
    assert.equal(boot.user.id, cashierId);
    // The owner cannot use PIN sign-in, even with a counter key.
    await call("auth/pin-login", "", { ...deviceBody, userId: "user-owner", pin: "4826" }, 403);

    // A staff member of another branch cannot sign in on this counter.
    await call("users", owner, { ...cashierRecord, name: "Counter Cashier", branchIds: ["mumbai"] });
    await call("auth/pin-login", "", { ...deviceBody, userId: cashierId, pin: "4826" }, 403);
    await call("users", owner, { ...cashierRecord, name: "Counter Cashier", branchIds: ["pune"] });

    // Switching the counter off stops PIN sign-in.
    await call(`devices/${device.id}/pin-key`, manager, { disable: true });
    await call("auth/pin-login", "", { ...deviceBody, userId: cashierId, pin: "4826" }, 401);
    await call("auth/pin-staff", "", deviceBody, 401);
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("five wrong PINs lock PIN sign-in for five minutes and are audited", async () => {
  const { db, app, call, login } = await setup();
  try {
    const owner = await login("owner");
    await call("users/user-cashier/pin", owner, { pin: "5937" });
    const device = (await call("devices/enroll", owner, { name: "Till 2" })).json;
    const { key } = (await call(`devices/${device.id}/pin-key`, owner, {})).json;
    const attempt = (pin: string, status: number) =>
      call("auth/pin-login", "", { deviceId: device.id, deviceKey: key, userId: "user-cashier", pin }, status);
    for (let i = 0; i < 4; i++) await attempt("0000", 401);
    const locked = await attempt("0000", 429);
    assert.match(locked.json.error, /locked for 5 minutes/);
    // Even the right PIN is refused while locked.
    assert.match((await attempt("5937", 429)).json.error, /Try again in/);
    const audit = (await call("bootstrap", owner)).json.audit;
    assert.equal(audit.filter((a: any) => a.action === "pin-failed" && a.subject === "user-cashier").length, 4);
    assert.equal(audit.filter((a: any) => a.action === "pin-lockout").length, 1);
    // After the lock expires the right PIN works and the counter resets.
    await db.query("UPDATE records SET data = jsonb_set(data, '{lockedUntil}', to_jsonb($1::text)) WHERE kind='pinLock' AND id='user-cashier'",
      [new Date(Date.now() - 1000).toISOString()]);
    await attempt("5937", 200);
    // Resetting the PIN also clears failures.
    await attempt("0000", 401);
    await call("users/user-cashier/pin", owner, { pin: "7319" });
    await attempt("7319", 200);
    await call("users/user-cashier/pin", owner, { clear: true });
    await attempt("7319", 403);
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("shift close accepts a note count that must match, and the summary splits tenders, refunds and drawer cash", async () => {
  const { db, app, call, login } = await setup();
  try {
    const owner = await login("owner");
    const cashier = await login("cashier");
    const shift = (await call("shifts/open", owner, { openingCash: 50000 })).json;
    const service = (await call("products", owner, { name: "Fitting", sku: "WSD-FIT", brand: "Shop", category: "Service",
      unit: "Job", retailPrice: 10000, type: "service", taxRate: 0 })).json;
    const cashSale = (await call("invoices", owner, { transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: service.id, qty: 1 }], tenders: [{ type: "Cash", amount: 20000, confirmed: true }] })).json;
    await call("invoices", owner, { transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: service.id, qty: 2 }], tenders: [{ type: "UPI", amount: 20000, confirmed: true, reference: "UPI-1" }] });
    await call("invoices/" + cashSale.id + "/returns", owner, { transactionId: randomUUID(), condition: "sellable",
      reason: "Cancelled", refundType: "Cash", lines: [{ lineId: cashSale.lines[0].id, quantity: 1 }] });
    await call("shifts/" + shift.id + "/cash-movements", owner, { transactionId: randomUUID(), direction: "out", amount: 5000, reason: "Tea" });

    const summary = (await call("shifts/" + shift.id + "/summary", owner)).json;
    assert.equal(summary.invoices, 2);
    assert.deepEqual(summary.tenders, { Cash: 10000, UPI: 20000 });
    assert.deepEqual(summary.refunds, { Cash: 10000 });
    assert.equal(summary.cashMovements.length, 1);
    assert.equal(summary.expectedCash, 50000 + 10000 - 10000 - 5000);
    await call("shifts/" + shift.id + "/summary", cashier, undefined, 403);

    // 2 × ₹200 + 1 × ₹50 + ₹2.50 coins = ₹452.50, against ₹450 expected.
    const count = { "20000": 2, "5000": 1, coins: 250, "50000": 0 };
    await call("shifts/" + shift.id + "/close", owner, { countedCash: 45000, denominations: count }, 400);
    await call("shifts/" + shift.id + "/close", owner, { denominations: { "300": 1 } }, 400);
    await call("shifts/" + shift.id + "/close", owner, { denominations: { "20000": -1 } }, 400);
    const closed = (await call("shifts/" + shift.id + "/close", owner, { denominations: count })).json;
    assert.equal(closed.countedCash, 45250);
    assert.equal(closed.variance, 250);
    assert.deepEqual(closed.denominations, { "20000": 2, "5000": 1, coins: 250 });
    const after = (await call("shifts/" + shift.id + "/summary", owner)).json;
    assert.equal(after.countedCash, 45250);
    assert.equal(after.variance, 250);
  } finally {
    await app.close();
    await db.close?.();
  }
});
