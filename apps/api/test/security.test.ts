// Security review fixes: cost hiding, PIN hardening, bound approvals, attachments,
// exact public paths and the cashier's return lookup.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate } from "../src/db.js";
import { createApp, isCostKey } from "../src/app.js";
import { seed } from "../src/seed.js";

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]).toString("base64");

async function setup() {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  async function call(path: string, token: string, body?: any, status = 200, method?: string) {
    const response = await app.inject({
      method: (method || (body === undefined ? "GET" : "POST")) as any, url: "/api/v1/" + path, payload: body,
      headers: token ? { authorization: "Bearer " + token } : {},
    });
    assert.equal(response.statusCode, status, path + ": " + response.body);
    const json = String(response.headers["content-type"] || "").includes("json") ? response.json() : undefined;
    return { json, body: response.body, headers: response.headers, raw: response.rawPayload };
  }
  const login = async (role: string) => (await call("auth/login", "", {
    email: role + "@motorline.local", password: "MotorlineDemo123!", branchId: "pune",
  })).json.token;
  return { db, app, call, login };
}

/** Every key path in [value] that looks like a cost, margin or cost-based price. */
function costKeys(value: any, path = "$", found: string[] = []): string[] {
  if (Array.isArray(value)) value.forEach((entry, index) => costKeys(entry, `${path}[${index}]`, found));
  else if (value && typeof value === "object")
    for (const [key, entry] of Object.entries(value)) {
      if (isCostKey(key)) found.push(`${path}.${key}`);
      costKeys(entry, `${path}.${key}`, found);
    }
  return found;
}

test("cost-like keys are recognised; label margins are not", () => {
  for (const key of ["cost", "lastPurchaseCost", "landedCost", "unitCost", "oldCost", "newCost", "margin", "oldMargin",
    "newMargin", "costHike", "costHikeThreshold", "suggestedPrice", "costChangeId"])
    assert.ok(isCostKey(key), key);
  for (const key of ["marginTopMm", "marginLeftMm", "retailPrice", "total", "name"]) assert.ok(!isCostKey(key), key);
});

test("a cashier never receives cost, margin or supplier data, even after a purchase bill with a cost hike", async () => {
  const { app, db, call, login } = await setup();
  try {
    const manager = await login("manager");
    const cashier = await login("cashier");
    const bill = (cost: number, billNumber: string) => call("purchase-bills", manager, {
      transactionId: randomUUID(), supplierId: "supplier-1", billNumber, billDate: "2026-11-20",
      lines: [{ productId: "filter", quantity: 5, cost, binId: "bin-a1" }],
    });
    await bill(20000, "S-1");
    const hiked = (await bill(30000, "S-2")).json;
    assert.ok(costKeys(hiked).length > 0, "the manager sees the costs");
    assert.ok((await call("cost-changes", manager)).json.rows?.length !== 0);

    const boot = (await call("bootstrap", cashier)).json;
    assert.deepEqual(costKeys(boot), []);
    assert.deepEqual(boot.suppliers, []);
    assert.ok(boot.products.length > 0);
    // Responses to the cashier's own actions are cleaned too.
    const shift = (await call("shifts/open", cashier, { openingCash: 0 })).json;
    const sale = await call("invoices", cashier, {
      transactionId: randomUUID(), shiftId: shift.id, customerId: "customer-1",
      lines: [{ productId: "filter", qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 10000000, confirmed: true }],
    });
    assert.deepEqual(costKeys(sale.json), []);
    const lookup = await call(`returns/lookup?q=${encodeURIComponent(sale.json.number)}`, cashier);
    assert.deepEqual(costKeys(lookup.json), []);
    await call("cost-changes", cashier, undefined, 403);
    // The manager's bootstrap still has costs and suppliers.
    const managerBoot = (await call("bootstrap", manager)).json;
    assert.ok(managerBoot.suppliers.length > 0);
    assert.ok(costKeys(managerBoot).length > 0);
  } finally {
    await app.close();
    await db.close?.();
  }
});

async function pinCounter(call: any, owner: string, pin: string) {
  await call("users/user-cashier/pin", owner, { pin });
  const device = (await call("devices/enroll", owner, { name: "Till" })).json;
  const { key } = (await call(`devices/${device.id}/pin-key`, owner, {})).json;
  return { device, key };
}

test("twenty concurrent wrong PINs lock after five", async () => {
  const { app, db, call, login } = await setup();
  try {
    const owner = await login("owner");
    const { device, key } = await pinCounter(call, owner, "5937");
    const responses = await Promise.all(Array.from({ length: 20 }, () => app.inject({
      method: "POST", url: "/api/v1/auth/pin-login",
      payload: { deviceId: device.id, deviceKey: key, userId: "user-cashier", pin: "0000" },
    })));
    const codes = responses.map((r) => r.statusCode);
    assert.equal(codes.filter((c) => c === 401).length, 4, codes.join(","));
    assert.equal(codes.filter((c) => c === 429).length, 16, codes.join(","));
    const audit = (await call("bootstrap", owner)).json.audit;
    assert.equal(audit.filter((a: any) => a.action === "pin-failed").length, 4);
    assert.equal(audit.filter((a: any) => a.action === "pin-lockout").length, 1);
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("a counter that sees too many wrong PINs stops PIN sign-in for everyone on it", async () => {
  const { app, db, call, login } = await setup();
  try {
    const owner = await login("owner");
    const { device, key } = await pinCounter(call, owner, "5937");
    await call("users/user-manager/pin", owner, { pin: "6284" });
    await call("users/user-inventory/pin", owner, { pin: "7395" });
    const attempt = (userId: string, pin: string) => app.inject({
      method: "POST", url: "/api/v1/auth/pin-login", payload: { deviceId: device.id, deviceKey: key, userId, pin },
    });
    // 4 wrong each (under the personal lock) for three people, then three more: 15 on this counter.
    for (const userId of ["user-cashier", "user-manager", "user-inventory"])
      for (let i = 0; i < 4; i++) assert.equal((await attempt(userId, "0000")).statusCode, 401);
    // Reset personal counts so only the counter limit applies.
    await db.query("UPDATE records SET data = jsonb_set(data, '{failures}', '0') WHERE kind='pinLock'");
    assert.equal((await attempt("user-cashier", "0000")).statusCode, 401);
    assert.equal((await attempt("user-cashier", "0000")).statusCode, 401);
    const locked = await attempt("user-manager", "0000");
    assert.equal(locked.statusCode, 429);
    assert.match(locked.json().error, /on this counter/);
    // Even the right PIN of someone else is refused on this counter for now.
    assert.equal((await attempt("user-manager", "6284")).statusCode, 429);
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("PIN sessions are short and end when the counter is switched off; PINs need not be unique", async () => {
  const { app, db, call, login } = await setup();
  try {
    const owner = await login("owner");
    const { device, key } = await pinCounter(call, owner, "5937");
    // No uniqueness oracle: another person may get the same PIN.
    await call("users/user-manager/pin", owner, { pin: "5937" });
    const signIn = async () => (await call("auth/pin-login", "", { deviceId: device.id, deviceKey: key, userId: "user-cashier", pin: "5937" })).json;
    const session = await signIn();
    assert.ok(Date.parse(session.expiresAt) - Date.now() <= 8 * 3600000 + 5000, "never longer than sessionHours");
    await call("bootstrap", session.token);
    await call(`devices/${device.id}/pin-key`, owner, { disable: true });
    const ended = await call("bootstrap", session.token, undefined, 401);
    assert.match(ended.json.error, /switched off/);
    // Turning it on again issues a new key; the old session stays ended.
    await call(`devices/${device.id}/pin-key`, owner, {});
    await call("bootstrap", session.token, undefined, 401);
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("approvals are bound to the amount and subject they approve", async () => {
  const { app, db, call, login } = await setup();
  try {
    const manager = await login("manager");
    const cashier = await login("cashier");
    const shift = (await call("shifts/open", cashier, { openingCash: 0 })).json;
    const transactionId = randomUUID();
    const sale = (discount: number, approvalId: string, customerId?: string) => ({
      transactionId, shiftId: shift.id, discount, discountReason: "Regular", discountApprovalId: approvalId,
      ...(customerId ? { customerId } : {}),
      lines: [{ productId: "filter", qty: 2, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 10000000, confirmed: true }],
    });
    // A discount approval must say how much it covers.
    await call("approvals", manager, { action: "discount", transactionId, reason: "Regular" }, 400);
    const approval = (await call("approvals", manager, { action: "discount", transactionId, reason: "Regular", amount: 500, subjectId: "9000000101" })).json;
    assert.equal(approval.amount, 500);
    assert.equal(approval.subjectId, "customer-1");
    await call("invoices", cashier, sale(600, approval.id, "customer-1"), 403); // more than approved
    await call("invoices", cashier, sale(500, approval.id), 403); // another customer (walk-in)
    await call("invoices", cashier, sale(500, approval.id, "customer-1"));
    // A return approval names the invoice.
    await call("approvals", manager, { action: "return", transactionId, reason: "Damaged" }, 400);
    await call("approvals", manager, { action: "return", transactionId, reason: "Damaged", subjectId: "NOPE-1" }, 404);
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("attachments: stock roles only for bills, cashiers only their photos, strict file checks and safe headers", async () => {
  const { app, db, call, login } = await setup();
  try {
    const manager = await login("manager");
    const cashier = await login("cashier");
    const billPhoto = (await call("attachments", manager, { contentType: "image/jpeg", data: JPEG, name: "../bill \"x\".jpg" })).json;
    await call("purchase-bills", manager, {
      transactionId: randomUUID(), supplierId: "supplier-1", billNumber: "PH-1", billDate: "2026-11-20",
      lines: [{ productId: "filter", quantity: 1, cost: 20000, binId: "bin-a1" }], photoIds: [billPhoto.id],
    });
    await call(`attachments/${billPhoto.id}`, cashier, undefined, 404);
    const served = await call(`attachments/${billPhoto.id}`, manager);
    assert.equal(served.headers["x-content-type-options"], "nosniff");
    assert.equal(served.headers["content-disposition"], 'inline; filename="bill_x.jpg"');
    // Cashiers upload photos only (no PDFs) and can read their own.
    await call("attachments", cashier, { contentType: "application/pdf", data: Buffer.from("%PDF-1.4").toString("base64") }, 403);
    const own = (await call("attachments", cashier, { contentType: "image/jpeg", data: JPEG, name: "scratch.jpg" })).json;
    await call(`attachments/${own.id}`, cashier);
    // A manager's job photo is visible to a cashier once it is on a job card... but not a loose upload.
    const loose = (await call("attachments", manager, { contentType: "image/jpeg", data: JPEG })).json;
    await call(`attachments/${loose.id}`, cashier, undefined, 404);
    // WebP must carry the full RIFF....WEBP header.
    const fakeWebp = Buffer.concat([Buffer.from("RIFF"), Buffer.alloc(4), Buffer.from("AVI LIST")]).toString("base64");
    await call("attachments", manager, { contentType: "image/webp", data: fakeWebp }, 400);
    const webp = Buffer.concat([Buffer.from("RIFF"), Buffer.alloc(4), Buffer.from("WEBPVP8 ")]).toString("base64");
    await call("attachments", manager, { contentType: "image/webp", data: webp });
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("only the exact public paths skip sign-in; unknown emails still get the generic error", async () => {
  const { app, db, call } = await setup();
  try {
    await call("health", "");
    await call("x/health", "", undefined, 401);
    await call("bootstrap/auth/login", "", {}, 401);
    await call("devices/auth/pin-login", "", {}, 401);
    const unknown = await call("auth/login", "", { email: "nobody@motorline.local", password: "whatever" }, 401);
    assert.equal(unknown.json.error, "Invalid email or password.");
  } finally {
    await app.close();
    await db.close?.();
  }
});

test("a cashier's return lookup is exact, recent and without tender references", async () => {
  const { app, db, call, login } = await setup();
  try {
    const cashier = await login("cashier");
    const manager = await login("manager");
    const shift = (await call("shifts/open", cashier, { openingCash: 0 })).json;
    const sale = (await call("invoices", cashier, {
      transactionId: randomUUID(), shiftId: shift.id, customerId: "customer-1",
      lines: [{ productId: "filter", qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "UPI", amount: 100, confirmed: true, reference: "UPI-REF-1" }, { type: "Cash", amount: 10000000, confirmed: true }],
    })).json;
    const exact = (await call(`returns/lookup?q=${encodeURIComponent(sale.number)}`, cashier)).json;
    assert.equal(exact[0].id, sale.id);
    assert.ok(exact[0].tenders.every((t: any) => Object.keys(t).every((k) => ["type", "amount"].includes(k))));
    assert.equal(exact[0].customer?.phone, undefined);
    const partial = String(sale.number).slice(-3);
    assert.equal((await call(`returns/lookup?q=${encodeURIComponent(partial)}`, cashier)).json.length, 0);
    assert.ok((await call(`returns/lookup?q=${encodeURIComponent(partial)}`, manager)).json.length >= 1);
    assert.ok((await call("returns/lookup?q=9000000101", cashier)).json.some((i: any) => i.id === sale.id));
    assert.equal((await call("returns/lookup?q=000101", cashier)).json.length, 0);
  } finally {
    await app.close();
    await db.close?.();
  }
});
