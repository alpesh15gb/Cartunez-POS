import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createApp } from "../src/app.js";
import { connectDatabase, getRecord, migrate, putRecord } from "../src/db.js";
import { seed } from "../src/seed.js";

test("closed shift party payments survive cancellation, spent advances cannot be withdrawn and tender reports reconcile core refunds", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    async function call(path: string, token: string, payload?: any, expected = 200) {
      const response = await app.inject({ method: payload === undefined ? "GET" : "POST", url: "/api/v1/" + path,
        payload, headers: token ? { authorization: "Bearer " + token } : {} });
      assert.equal(response.statusCode, expected, path + ": " + response.body);
      return response.json();
    }
    const login = async (role: string, branchId = "pune") => (await call("auth/login", "", {
      email: role + "@motorline.local", password: "MotorlineDemo123!", branchId })).token;
    const cashier = await login("cashier"), owner = await login("owner"), away = await login("owner", "mumbai");
    const customer = (await call("customers", owner, { name: "Settlement customer" })).id;
    const supplier = (await call("suppliers", owner, { name: "Settlement supplier" })).id;
    const cash = { partyId: customer, partyKind: "customer", amount: 50000, mode: "Cash" };
    const supplierCash = { ...cash, partyKind: "supplier", partyId: supplier };
    await call("party-payments", cashier, cash, 409);
    await call("party-payments", cashier, { ...cash, fromDrawer: false }, 409);
    await call("party-payments", owner, supplierCash, 409);
    const outside = await call("party-payments", owner, { ...supplierCash, fromDrawer: false });
    assert.equal(outside.shiftId, null);
    const first = await call("shifts/open", cashier, { openingCash: 0 });
    const original = await call("party-payments", cashier, cash);
    const reverse = "party-payments/" + original.id + "/void";
    const reason = { reason: "Cash handed back to customer", transactionId: randomUUID() };
    await call("shifts/" + first.id + "/close", cashier, { countedCash: 50000, reviewedExpectedCash: 50000 });
    const closedSummary = await call("shifts/" + first.id + "/summary", cashier);
    await call(reverse, away, reason, 404);
    await call(reverse, cashier, reason, 403);
    await call(reverse, owner, reason, 409);
    const second = await call("shifts/open", owner, { openingCash: 100000 });
    const reversed = await call(reverse, owner, reason);
    assert.equal(reversed.reversesId, original.id);
    assert.equal(reversed.shiftId, second.id);
    assert.equal((await call(reverse, owner, reason)).id, reversed.id);
    await call(reverse, owner, { ...reason, transactionId: randomUUID() }, 409);
    await call("party-payments/" + reversed.id + "/void", owner, { reason: "Second reversal" }, 409);
    assert.deepEqual(await getRecord(db, "demo", "partyPayment", original.id), original);
    await assert.rejects(db.query("UPDATE records SET data='{}' WHERE kind='partyPayment' AND id=$1", [original.id]));
    await assert.rejects(db.query("DELETE FROM records WHERE kind='partyPayment' AND id=$1", [original.id]));
    assert.deepEqual(await call("shifts/" + first.id + "/summary", cashier), closedSummary);
    assert.deepEqual([closedSummary.expectedCash, closedSummary.cashIn, closedSummary.partyPayments.length], [50000, 50000, 1]);
    const current = () => call("shifts/" + second.id + "/summary", owner);
    const summary = await current();
    assert.deepEqual([summary.cashOut, summary.expectedCash, summary.partyPayments[0].reversesId], [50000, 50000, original.id]);
    const account = () => call("customers/" + customer + "/summary", owner);
    assert.equal((await account()).balance, 0);

    const part = await call("products", owner, { name: "Refundable battery", retailPrice: 10000,
      taxRate: 0, coreCharge: 5000, universal: true });
    await call("inventory/adjust", owner, { productId: part.id, binId: "bin-a1", quantity: 3, reason: "Initial bin count" });
    const sale = (tenders: any[]) => call("invoices", owner, { transactionId: randomUUID(), shiftId: second.id,
      customerId: customer, lines: [{ productId: part.id, binId: "bin-a1", qty: 1 }], tenders });
    const credit = await sale([{ type: "Credit", amount: 15000 }]);
    assert.equal(credit.total, 15000);
    const report = () => call("reports/tenders", owner);
    let totals = (await report()).totals;
    assert.deepEqual([totals.collected, totals.refunded, totals.net, totals.accountApplied], [0, 0, 0, 15000]);
    const deposit = { invoiceId: credit.id, productId: part.id, quantity: 1, refundType: "Cash", reason: "Core received" };
    const preview = await call("core-returns/preview", owner, deposit);
    assert.deepEqual(preview.refunds, [{ type: "Credit", amount: 5000 }]);
    await call("core-returns/preview", cashier, deposit, 403);
    await call("core-returns/preview", away, deposit, 404);
    await call("core-returns", owner, { ...deposit, transactionId: randomUUID(), reviewedRefunds: [{ type: "Cash", amount: 5000 }] }, 409);
    const approved = { ...deposit, transactionId: randomUUID(), reviewedRefunds: [{ amount: 5000, type: "Credit" }] };
    const core = await call("core-returns", owner, approved);
    assert.equal((await call("core-returns", owner, approved)).id, core.id);
    assert.equal((await account()).balance, 10000);
    assert.equal((await current()).expectedCash, 50000);
    totals = (await report()).totals;
    assert.deepEqual([totals.refunded, totals.accountReturned, totals.accountNet], [0, 5000, 10000]);

    const split = await sale([{ type: "Cash", amount: 8000, confirmed: true },
      { type: "UPI", amount: 5000, confirmed: true, reference: "MULTI-001" }, { type: "Credit", amount: 5000 }]);
    assert.equal(split.change, 3000);
    const splitCore = { ...deposit, invoiceId: split.id, refundType: "" };
    const allocation = await call("core-returns/preview", owner, splitCore);
    const principal = await call("invoices/" + split.id + "/returns", owner, { transactionId: randomUUID(), reason: "Returned battery",
      condition: "sellable", lines: [{ lineId: split.lines[0].id, quantity: 1 }] });
    const issued = await call("core-returns", owner, { ...splitCore, transactionId: randomUUID(), reviewedRefunds: allocation.refunds });
    for (const type of ["Cash", "UPI", "Credit"]) {
      const combined = [...principal.refunds, ...issued.refunds].filter(p => p.type === type).reduce((n, p) => n + p.amount, 0);
      assert.equal(combined, 5000, type);
    }
    totals = (await report()).totals;
    assert.deepEqual([totals.collected, totals.refunded, totals.net, totals.accountNet], [10000, 10000, 0, 10000]);
    assert.equal((await current()).expectedCash, 50000);
    // Recorded prepaid website tenders must still be returned through the original gateway.
    const online = { ...credit, id: "historical-online", tenders: [{ type: "Online", amount: credit.total }] };
    await putRecord(db, "demo", "invoice", online, "pune");
    const website = await call("core-returns/preview", owner, { ...deposit, invoiceId: online.id });
    assert.deepEqual(website.refunds, [{ type: "Online", amount: 5000 }]);

    const prepaid = (await call("customers", owner, { name: "Advance customer" })).id;
    const path = "customers/" + prepaid;
    const advance = await call(path + "/advances", owner, { amount: 20000, mode: "Cash" });
    const refund = await call(path + "/advances/refund", owner, { amount: 5000, mode: "Cash", reason: "Requested by customer" });
    assert.equal((await call(path + "/summary", owner)).availableAdvance, 15000);
    await call("party-payments/" + refund.id + "/void", owner, { reason: "Cash retained by store" });
    assert.equal((await call(path + "/summary", owner)).availableAdvance, 20000);
    await call("invoices", owner, { transactionId: randomUUID(), shiftId: second.id, customerId: prepaid,
      lines: [{ productId: part.id, binId: "bin-a1", qty: 1 }], tenders: [{ type: "Advance", amount: 15000 }] });
    await call("party-payments/" + advance.id + "/void", owner, { reason: "No longer available" }, 409);
    assert.equal((await call(path + "/summary", owner)).availableAdvance, 5000);
  } finally {
    await app.close();
    await db.close();
  }
});
