import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

// QA audit #1 and #2: supplier balances posted by a bill, and the Purchase Receipts
// report covering every way stock is received (goods receipt, PO bill, direct bill).
test("Supplier bill balance and Purchase Receipts cover all receiving without double counting", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db, {});
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({
        method: method as any, url: "/api/v1/" + path, payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.headers["content-type"]?.toString().includes("json") ? response.json() : response.body;
    };
    const get = (path: string, token: string) => call(path, undefined, token, 200, "GET");
    const owner = (await call("auth/login", { email: "owner@motorline.local", password: "MotorlineDemo123!" })).token;
    const balance = async (supplierId: string) => (await get("bootstrap", owner)).partyBalances.suppliers[supplierId] ?? 0;
    const part = await call("products", {
      name: "QA Brake Pad", sku: "QA-PAD-60", category: "Brakes", unit: "Each", cost: 6000, retailPrice: 9000, taxRate: 0,
    }, owner);

    // #1: a ₹60 bill leaves ₹60 / ₹40 / ₹0 on the supplier's account for ₹0 / ₹20 / ₹60 paid now.
    for (const [paid, due] of [[0, 6000], [2000, 4000], [6000, 0]]) {
      const supplier = await call("suppliers", { name: `Balance supplier ${paid}` }, owner);
      const bill = await call("purchase-bills", {
        transactionId: randomUUID(), supplierId: supplier.id, billNumber: `BAL-${paid}`, billDate: "2026-11-22",
        lines: [{ productId: part.id, quantity: 1, cost: 6000, binId: "bin-a1" }],
        ...(paid ? { paidNow: { amount: paid, mode: "Cash", fromDrawer: false } } : {}),
      }, owner);
      assert.equal(bill.total, 6000);
      assert.equal(await balance(supplier.id), due, `paid ${paid}`);
    }
    // Freight and discount: ₹60 items + ₹10 freight − ₹5 discount = ₹65, ₹20 paid → ₹45 owed (what the dialog previews).
    const extras = await call("suppliers", { name: "Freight supplier" }, owner);
    const freightBill = await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: extras.id, billNumber: "FR-1", billDate: "2026-11-22",
      lines: [{ productId: part.id, quantity: 1, cost: 6000, binId: "bin-a1" }],
      otherCharges: 1000, discount: 500, paidNow: { amount: 2000, mode: "UPI" },
    }, owner);
    assert.equal(freightBill.total, 6500);
    assert.equal(await balance(extras.id), 4500);

    // #2: the audit's path. PO for 2 units at ₹60; receive 1 without a bill, then a PO-linked bill for the other.
    const supplier = await call("suppliers", { name: "Receiving supplier" }, owner);
    const order = await call("purchase-orders", { supplierId: supplier.id, lines: [{ productId: part.id, quantity: 2, cost: 6000 }] }, owner);
    await call(`purchase-orders/${order.id}/receive`, {
      transactionId: randomUUID(), lines: [{ productId: part.id, quantity: 1, binId: "bin-a1" }],
    }, owner);
    await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: supplier.id, billNumber: "PO-BILL-1", billDate: "2026-11-22",
      purchaseOrderId: order.id, lines: [{ productId: part.id, quantity: 1, cost: 6000, binId: "bin-a1" }],
    }, owner);
    const po = (await get("bootstrap", owner)).purchaseOrders.find((o: any) => o.id === order.id);
    assert.equal(po.status, "received");

    const forPo = await get(`reports/purchase-receipts?supplierId=${supplier.id}`, owner);
    assert.deepEqual(forPo.rows.map((r: any) => r.source).sort(), ["Goods receipt", "PO bill"]);
    assert.ok(forPo.rows.every((r: any) => r.purchaseOrderId === order.id));
    assert.equal(forPo.totals.quantity, 2);
    assert.equal(forPo.totals.total, 12000);

    // A direct bill from the same supplier also shows up, once.
    await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: supplier.id, billNumber: "DIRECT-1", billDate: "2026-11-22",
      lines: [{ productId: part.id, quantity: 1, cost: 6000, binId: "bin-a1" }],
    }, owner);
    const all = await get(`reports/purchase-receipts?supplierId=${supplier.id}`, owner);
    assert.deepEqual(all.rows.map((r: any) => r.source).sort(), ["Goods receipt", "PO bill", "Supplier bill"]);
    assert.equal(all.totals.quantity, 3);
    assert.equal(all.totals.total, 18000);
    assert.equal(new Set(all.rows.map((r: any) => r.id)).size, 3);
    // Every unit the stock movement log shows as received is in the report: no more, no less.
    const moves = await get(`reports/stock-movement?sku=${part.sku}`, owner);
    const report = await get(`reports/purchase-receipts?sku=${part.sku}`, owner);
    const receivedUnits = moves.rows.filter((m: any) => m.quantity > 0).reduce((n: number, m: any) => n + m.quantity, 0);
    assert.equal(report.totals.quantity, receivedUnits);

    // The CSV export has the same lines, totals and the source column.
    const csv = String(await get(`reports/purchase-receipts?supplierId=${supplier.id}&format=csv`, owner));
    const [header, ...lines] = csv.split("\r\n");
    const cols = header.split(",").map((c) => c.replace(/"/g, ""));
    assert.ok(cols.includes("source"));
    assert.equal(lines.length, 3);
    const cell = (line: string, name: string) => line.split(",")[cols.indexOf(name)].replace(/"/g, "");
    assert.equal(lines.reduce((n, l) => n + Number(cell(l, "quantity")), 0), 3);
    assert.equal(lines.reduce((n, l) => n + Number(cell(l, "total (INR)")), 0), 180);

    // A cancelled bill's stock goes back out, so it leaves the report.
    const direct = (await get("bootstrap", owner)).purchaseBills.find((b: any) => b.billNumber === "DIRECT-1");
    await call(`purchase-bills/${direct.id}/void`, { reason: "Entered twice" }, owner);
    assert.equal((await get(`reports/purchase-receipts?supplierId=${supplier.id}`, owner)).totals.quantity, 2);
  } finally {
    await app.close();
    await db.close?.();
  }
});
