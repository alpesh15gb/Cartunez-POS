import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createApp } from "../src/app.js";
import { connectDatabase, getRecord, migrate, putRecord, records } from "../src/db.js";
import { seed } from "../src/seed.js";

test("supplier bill accounting through the public purchase, catalog and report routes", async t => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  t.after(async () => { await app.close(); await db.close(); });
  const token = (await app.inject({ method: "POST", url: "/api/v1/auth/login",
    payload: { email: "owner@motorline.local", password: "MotorlineDemo123!" } })).json().token;
  const headers = { authorization: "Bearer " + token };
  const call = async (path: string, payload?: any, status = 200) => {
    const r = await app.inject({ method: payload ? "POST" : "GET", url: "/api/v1/" + path, payload, headers });
    assert.equal(r.statusCode, status, path + ": " + r.body);
    return r.json();
  };
  const part = (name: string, fields = {}) => call("products", { name, sku: name, cost: 80, retailPrice: 200, ...fields });
  const line = (productId: string, cost: number, quantity = 1, fields = {}) => ({ productId, binId: "bin-a1", cost, quantity, ...fields });
  const bill = (lines: any[], fields = {}, status = 200) => call("purchase-bills",
    { supplierId: "supplier-1", billNumber: randomUUID(), lines, ...fields }, status);
  const cancel = (id: string) => call("purchase-bills/" + id + "/void", { reason: "Supplier correction" });
  const current = async (id: string) => (await getRecord(db, "demo", "product", id))!;
  const economics = async (id: string) => {
    const p = await current(id);
    return [p.cost, p.lastPurchaseCost, p.retailPrice];
  };
  const credit = (billId: string, lines: any[], status = 200) => call("purchase-returns",
    { supplierId: "supplier-1", billId, transactionId: randomUUID(), reason: "Returned parts", lines }, status);

  await t.test("bill payment reduces payable, and exact landed amounts survive unit rounding", async () => {
    const p = await part("Paise");
    const supplier = await call("suppliers", { name: "Accounting regression" });
    const b = await bill([line(p.id, 100, 3)], { supplierId: supplier.id, otherCharges: 1,
      paidNow: { amount: 10, mode: "UPI", refund: true, partyKind: "customer", date: "junk", direction: "in" } });
    assert.equal(b.total, 301);
    assert.equal(b.lines[0].landedCost, 100);
    assert.equal(b.lines[0].landedTotal, 301);
    const payment = (await records(db, "demo", "partyPayment")).find(p => p.billId === b.id)!;
    assert.deepEqual([payment.refund, payment.direction, payment.partyId, payment.date], [false, "out", supplier.id, b.billDate]);
    assert.equal((await call("parties/suppliers/" + supplier.id + "/ledger")).balance, 291);
    assert.equal((await call("reports/purchase-receipts?sku=" + p.sku)).totals.total, 301);
    delete b.lines[0].landedTotal;
    await putRecord(db, "demo", "purchaseBill", b, "pune");
    assert.equal((await call("reports/purchase-receipts?sku=" + p.sku)).totals.total, 301);
    const free = await bill([line(p.id, 0, 1), line(p.id, 0, 2)], { otherCharges: 10 });
    assert.deepEqual(free.lines.map((l: any) => l.landedTotal), [3, 7]);
    await bill([line(p.id, 1)], { paidNow: { amount: -2, mode: "UPI" } }, 400);
    await bill([line(p.id, 100000000000, 1000000)], {}, 400);
  });

  await t.test("metadata-only saves preserve the supplier's cost and allow a subsequent void", async () => {
    const p = await part("Metadata");
    const b = await bill([line(p.id, 100, 3, { retailPrice: 300 })], { discount: 2 });
    assert.deepEqual(await economics(p.id), [99, 100, 300]);
    await call("products", { id: p.id, description: "New description", lastPurchaseCost: 999 });
    assert.deepEqual(await economics(p.id), [99, 100, 300]);
    await cancel(b.id);
    assert.deepEqual(await economics(p.id), [80, undefined, 200]);
    assert.equal((await current(p.id)).description, "New description");
    const costChange = await getRecord(db, "demo", "costChange", b.lines[0].costHike.costChangeId);
    assert.equal(costChange?.status, "cancelled");
    await call("cost-changes/" + costChange!.id + "/apply", {}, 409);
  });

  await t.test("later manual prices and receipt costs survive voiding a supplier bill", async () => {
    const p = await part("LaterEdits");
    const b = await bill([line(p.id, 100, 1, { retailPrice: 300 })]);
    await call("products", { id: p.id, retailPrice: 350 });
    await call("products", { id: p.id, retailPrice: 300 });
    const po = await call("purchase-orders", { supplierId: "supplier-1", lines: [line(p.id, 100)] });
    await call("purchase-orders/" + po.id + "/receive", { transactionId: randomUUID(), lines: [line(p.id, 100)] });
    await cancel(b.id);
    assert.deepEqual(await economics(p.id), [100, 100, 300]);
  });

  await t.test("voids in either order restore the last surviving purchase or manual value", async () => {
    for (const oldestFirst of [true, false]) {
      const p = await part("Order" + oldestFirst);
      const first = await bill([line(p.id, 99), line(p.id, 100, 1, { retailPrice: 300 })]);
      const second = await bill([line(p.id, 100, 1, { retailPrice: 400 })]);
      await cancel(oldestFirst ? first.id : second.id);
      assert.deepEqual(await economics(p.id), [100, 100, oldestFirst ? 400 : 300]);
      await cancel(oldestFirst ? second.id : first.id);
      assert.deepEqual(await economics(p.id), [80, undefined, 200]);
    }
    const p = await part("LegacySnapshot");
    const historical = await bill([line(p.id, 500, 1, { retailPrice: 600 })]);
    delete historical.productEconomics;
    await putRecord(db, "demo", "purchaseBill", historical, "pune");
    await cancel(historical.id);
    assert.deepEqual(await economics(p.id), [500, 500, 600]);
  });

  await t.test("duplicate source lines cap quantity, credit and serials per line", async () => {
    const p = await part("SerialCredits", { serialTracked: true });
    const b = await bill([line(p.id, 100, 1, { serials: ["A"] }), line(p.id, 237, 2, { serials: ["B", "C"], taxRate: 1800 })], { gst: true });
    const chosen = (serials: string[], billLineId?: string) => ({ productId: p.id, quantity: serials.length, binId: "bin-a1", serials, billLineId });
    await credit(b.id, [chosen(["B"])], 400);
    await credit(b.id, [chosen(["B"], b.lines[0].id)], 409);
    const one = await credit(b.id, [chosen(["B"], b.lines[1].id)]);
    const two = await credit(b.id, [chosen(["C"], b.lines[1].id), chosen(["A"], b.lines[0].id)]);
    assert.deepEqual([one.total, two.total, one.total + two.total], [280, 379, b.total]);
    assert.deepEqual(two.lines.map((l: any) => l.billLineId), [b.lines[1].id, b.lines[0].id]);
    await credit(b.id, [chosen(["B"], b.lines[1].id)], 400);
  });

  await t.test("grouped and line-specific website credits share one allowance", async () => {
    const p = await part("WebsiteCredits", { onlineOnly: true });
    const b = await bill([line(p.id, 100, 2), line(p.id, 500, 2)], { discount: 120 });
    const choice = (quantity: number, billLineId?: string) => ({ productId: p.id, quantity, billLineId });
    const a = await credit(b.id, [choice(1, b.lines[1].id)]);
    const b2 = await credit(b.id, [choice(3)]);
    assert.deepEqual([a.total, b2.total, a.total + b2.total], [450, 630, b.total]);
    assert.deepEqual(b2.lines.map((l: any) => [l.billLineId, l.quantity]), [[b.lines[0].id, 2], [b.lines[1].id, 1]]);
    await credit(b.id, [choice(1, b.lines[1].id)], 400);
    const older = await bill([line(p.id, 125, 2), line(p.id, 700)]);
    const oldReturn = await credit(older.id, [choice(1)]);
    delete oldReturn.lines[0].billLineId;
    await putRecord(db, "demo", "purchaseReturn", oldReturn, "pune");
    assert.equal((await credit(older.id, [choice(1, older.lines[1].id)])).total, 700);
    assert.equal((await credit(older.id, [choice(1, older.lines[0].id)])).total, 125);
    await credit(older.id, [choice(1)], 400);
  });

  await t.test("historical lines keep unique-price returns and guard ambiguous prices", async () => {
    const p = await part("HistoricalCredits");
    const older = async (cost: number) => {
      const b = await bill([line(p.id, 100), line(p.id, cost)]);
      for (const row of b.lines) delete row.id;
      await putRecord(db, "demo", "purchaseBill", b, "pune");
      return b;
    };
    const ambiguous = await older(200);
    const choice = { productId: p.id, quantity: 1, binId: "bin-a1" };
    await credit(ambiguous.id, [choice], 409);
    const equal = await older(100);
    assert.equal((await credit(equal.id, [choice, choice])).total, 200);
    await credit(equal.id, [choice], 400);

    const serialPart = await part("HistoricalSerialCredits", { serialTracked: true });
    const serialized = await bill([
      line(serialPart.id, 100, 1, { serials: ["OLD-A"] }),
      line(serialPart.id, 200, 1, { serials: ["OLD-B"] }),
    ]);
    for (const row of serialized.lines) delete row.id;
    await putRecord(db, "demo", "purchaseBill", serialized, "pune");
    const returnSerial = (serial: string) => ({ productId: serialPart.id, quantity: 1, binId: "bin-a1", serials: [serial] });
    await credit(serialized.id, [returnSerial("WRONG-SERIAL")], 409);
    assert.equal((await credit(serialized.id, [returnSerial("OLD-B")])).total, 200);
    await credit(serialized.id, [returnSerial("OLD-B")], 400);
    assert.equal((await credit(serialized.id, [returnSerial("OLD-A")])).total, 100);
  });
});
