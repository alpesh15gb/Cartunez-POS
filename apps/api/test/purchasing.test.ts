import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

// A 1x1 JPEG is enough to stand in for a photo of a handwritten supplier note.
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]).toString("base64");

test("Purchasing: supplier bills, photos, payments, returns and balances; customer credit", async () => {
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
      return response.headers["content-type"]?.toString().includes("json") ? response.json() : response.rawPayload;
    };
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const manager = await login("manager@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const boot = (token: string) => call("bootstrap", undefined, token, 200, "GET");
    const stockOf = async (token: string, productId: string, binId: string) =>
      (await boot(token)).stock.filter((s: any) => s.productId === productId && s.binId === binId).reduce((n: number, s: any) => n + s.quantity, 0);

    // A supplier with an old balance from before the POS (we owed them Rs 1,000).
    const supplier = await call("suppliers", { name: "Sri Auto Spares", phone: "9000000000", openingBalance: 100000, openingDate: "2026-11-01" }, manager);
    assert.equal(supplier.openingBalance, 100000);

    // The handwritten note is photographed and attached.
    await call("attachments", { contentType: "image/jpeg", data: "bm90IGEgcGhvdG8=" }, manager, 400);
    const note = await call("attachments", { contentType: "image/jpeg", data: JPEG, name: "note.jpg" }, manager);
    assert.equal(note.data, undefined);
    const bytes = await call(`attachments/${note.id}`, undefined, manager, 200, "GET");
    assert.equal(Buffer.from(bytes).toString("base64"), JPEG);

    // A brand-new item bought for the first time: created, then billed.
    const part = await call("products", {
      name: "LED Fog Lamp", sku: "FOG-LED-01", brand: "Philips", category: "Lighting", unit: "Each",
      cost: 0, retailPrice: 150000, taxRate: 1800, reorderLevel: 0, barcodes: ["CTZ-000000000001"],
    }, manager);
    const before = await stockOf(manager, "filter", "bin-a1");

    // Bill without GST: 4 lamps at 800 and 10 filters at 200, Rs 140 freight, Rs 40 off. Paid Rs 2,000 in cash on delivery.
    const billBody = {
      transactionId: randomUUID(),
      supplierId: supplier.id, billNumber: "A-117", billDate: "2026-11-20",
      lines: [
        { productId: part.id, quantity: 4, cost: 80000, binId: "bin-a1", retailPrice: 140000 },
        { productId: "filter", quantity: 10, cost: 20000, binId: "bin-a1" },
      ],
      otherCharges: 14000, discount: 4000,
      photoIds: [note.id],
      paidNow: { amount: 200000, mode: "Cash", fromDrawer: false },
    };
    await call("purchase-bills", billBody, cashier, 403);
    const bill = await call("purchase-bills", billBody, manager);
    assert.equal(bill.subtotal, 520000);
    assert.equal(bill.tax, 0);
    assert.equal(bill.total, 530000);
    // Same request again (retry) does not double the stock.
    assert.equal((await call("purchase-bills", billBody, manager)).id, bill.id);
    // Same bill number from the same supplier is refused.
    await call("purchase-bills", { ...billBody, transactionId: randomUUID() }, manager, 409);
    assert.equal(await stockOf(manager, part.id, "bin-a1"), 4);
    assert.equal(await stockOf(manager, "filter", "bin-a1"), before + 10);
    let data = await boot(manager);
    const lamp = data.products.find((p: any) => p.id === part.id);
    // Freight less discount (Rs 100) is spread by value: lamps carry 3200/5200 of it.
    assert.equal(lamp.cost, 80000 + Math.round(6154 / 4));
    assert.equal(lamp.retailPrice, 140000);
    // Balance: 1,000 opening + 5,300 bill - 2,000 paid = 4,300.
    assert.equal(data.partyBalances.suppliers[supplier.id], 430000);
    assert.equal(data.purchaseBills.length, 1);

    // A GST bill (the rare one): 18% on 2 lamps at 700.
    const gstBill = await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: supplier.id, billNumber: "GST-9", billDate: "2026-11-20", gst: true,
      lines: [{ productId: part.id, quantity: 2, cost: 70000, taxRate: 1800, binId: "bin-a1" }],
    }, manager);
    assert.equal(gstBill.tax, 25200);
    assert.equal(gstBill.total, 165200);

    // One lamp goes back to the supplier.
    await call("purchase-returns", {
      transactionId: randomUUID(), supplierId: supplier.id, billId: bill.id, reason: "Cracked lens",
      lines: [{ productId: part.id, quantity: 5, binId: "bin-a1", cost: 80000 }],
    }, manager, 400);
    const ret = await call("purchase-returns", {
      transactionId: randomUUID(), supplierId: supplier.id, billId: bill.id, reason: "Cracked lens",
      lines: [{ productId: part.id, quantity: 1, binId: "bin-a1", cost: 80000 }],
    }, manager);
    assert.equal(ret.total, 80000);
    // Two lines in one request cannot return more than the bill had (4 - 1 already back = 3 left).
    await call("purchase-returns", {
      transactionId: randomUUID(), supplierId: supplier.id, billId: bill.id, reason: "Excess",
      lines: [{ productId: part.id, quantity: 2, binId: "bin-a1" }, { productId: part.id, quantity: 2, binId: "bin-a1" }],
    }, manager, 400);
    // A bill with returns cannot be cancelled.
    await call(`purchase-bills/${bill.id}/void`, { reason: "Oops" }, owner, 409);
    assert.equal(await stockOf(manager, part.id, "bin-a1"), 5);

    // Pay the supplier by UPI.
    await call("party-payments", { partyKind: "supplier", partyId: supplier.id, amount: 100000, mode: "Barter" }, manager, 400);
    const paid = await call("party-payments", { partyKind: "supplier", partyId: supplier.id, amount: 100000, mode: "UPI", reference: "UTR123" }, manager);
    // 4,300 + 1,652 - 800 - 1,000 = 4,152.
    let ledger = await call(`parties/suppliers/${supplier.id}/ledger`, undefined, manager, 200, "GET");
    assert.equal(ledger.balance, 415200);
    assert.deepEqual(ledger.entries.map((e: any) => e.type), ["opening", "bill", "payment", "bill", "purchase-return", "payment"]);
    // A payment entered by mistake is cancelled.
    await call(`party-payments/${paid.id}/void`, { reason: "Entered twice" }, manager);
    ledger = await call(`parties/suppliers/${supplier.id}/ledger`, undefined, manager, 200, "GET");
    assert.equal(ledger.balance, 515200);

    // Cancelling the GST bill takes its stock back out.
    await call(`purchase-bills/${gstBill.id}/void`, { reason: "Wrong supplier" }, owner);
    assert.equal(await stockOf(manager, part.id, "bin-a1"), 3);
    assert.equal((await boot(manager)).partyBalances.suppliers[supplier.id], 350000);

    // Customer credit (udhaar): needs a customer, then raises their balance.
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    const sale = (customerId?: string) => ({
      transactionId: randomUUID(), shiftId: shift.id, customerId,
      lines: [{ productId: part.id, qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Credit", amount: 150000, confirmed: true }],
    });
    await call("invoices", sale(), cashier, 400);
    // A cash sale shows the price of one lamp.
    const cashSale = await call("invoices", { ...sale(), tenders: [{ type: "Cash", amount: 10000000, confirmed: true }] }, cashier);
    const price = cashSale.total;
    // Part paid in cash, the rest on the customer's account.
    const onCredit = await call("invoices", {
      ...sale("customer-1"),
      tenders: [{ type: "Cash", amount: 50000, confirmed: true }, { type: "Credit", amount: price - 50000 }],
    }, cashier);
    assert.equal(onCredit.tenders[1].confirmed, true);
    let customers = (await boot(cashier)).partyBalances.customers;
    assert.equal(customers["customer-1"], price - 50000);
    // The customer pays part of it; the cashier records it.
    await call("party-payments", { partyKind: "customer", partyId: "customer-1", amount: 20000, mode: "UPI" }, cashier);
    // Cashiers cannot pay suppliers.
    await call("party-payments", { partyKind: "supplier", partyId: supplier.id, amount: 100, mode: "Cash" }, cashier, 403);
    customers = (await boot(cashier)).partyBalances.customers;
    assert.equal(customers["customer-1"], price - 70000);
    // Cash received from the customer goes through the cashier's drawer.
    const cashPaid = await call("party-payments", { partyKind: "customer", partyId: "customer-1", amount: 1000, mode: "Cash" }, cashier);
    assert.equal(cashPaid.shiftId, shift.id);
    await call(`party-payments/${cashPaid.id}/void`, { reason: "Test" }, owner, 409);
    // Voiding the credit sale reverses it on the account (not as cash from the drawer).
    await call("shifts/open", { openingCash: 0 }, owner);
    await call(`party-payments/${cashPaid.id}/void`, { reason: "Test" }, owner);
    const voided = await call(`invoices/${onCredit.id}/void`, { transactionId: randomUUID(), reason: "Customer changed mind" }, owner);
    assert.ok(voided);
    const customerLedger = await call("parties/customers/customer-1/ledger", undefined, cashier, 200, "GET");
    assert.deepEqual(customerLedger.entries.map((e: any) => e.type), ["sale", "payment", "payment", "void", "void"]);
    // The void follows the tenders: the credit part comes off the account, the cash part
    // goes back in cash. The 200 rupees paid on account leave them in advance.
    assert.deepEqual(voided.refunds, [{ type: "Cash", amount: 50000 }, { type: "Credit", amount: price - 50000 }]);
    assert.equal(voided.refundType, "Mixed");
    assert.equal(customerLedger.balance, price - 50000 - 20000 - (price - 50000));
    // The advance is settled by giving the customer cash back.
    // Paying money back out needs a manager.
    await call("party-payments", { partyKind: "customer", partyId: "customer-1", amount: 20000, mode: "Cash", refund: true }, cashier, 403);
    await call("party-payments", { partyKind: "customer", partyId: "customer-1", amount: 20000, mode: "Cash", refund: true }, owner);
    assert.equal((await boot(cashier)).partyBalances.customers["customer-1"], 0);
    // Selling with no stock showing (default): allowed, stock goes negative until the bill is entered.
    const ghost = await call("products", { name: "Wiper blade 22in", retailPrice: 45000 }, manager);
    assert.match(ghost.sku, /^CT-\d{8}$/); // SKU created automatically
    assert.equal(ghost.cost, 0); // purchase price not needed
    assert.equal(ghost.category, "General");
    const sold = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: ghost.id, qty: 2, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 10000000, confirmed: true }],
    }, cashier);
    assert.ok(sold.id);
    assert.equal(await stockOf(manager, ghost.id, "bin-a1"), -2);
    // Switched off in Settings › Modules: blocked again.
    await call("settings", { features: { negativeStock: false } }, owner);
    await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: ghost.id, qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 10000000, confirmed: true }],
    }, cashier, 409);
    data = await boot(cashier);
    assert.equal(data.purchaseBills.length, 0); // cashiers do not see supplier bills
    assert.deepEqual(data.partyBalances.suppliers, {});
  } finally {
    await app.close();
  }
});
