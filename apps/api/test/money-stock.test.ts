// Money and stock review: per-tender refunds, exchange till, Tally, kit reservations,
// voided job invoices and restocked serials.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, getRecord, migrate, putRecord, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { shiftCashSummaries, shiftSummary } from "../src/shift-cash.js";
import { refundBreakdown } from "../src/returns.js";
import { tallyVouchers } from "../src/exports/tally.js";

test("refundBreakdown splits by the original tenders and adds up across partial returns", () => {
  const bill = { customerId: "c", tenders: [{ type: "Cash", amount: 70000 }, { type: "Credit", amount: 40000 }], change: 10000 };
  const first = refundBreakdown(bill, 0, 50000, "UPI");
  assert.deepEqual(first, [{ type: "UPI", amount: 30000 }, { type: "Credit", amount: 20000 }]);
  const rest = refundBreakdown(bill, 50000, 50000, "UPI");
  assert.equal(first[0].amount + rest[0].amount, 60000, "cash net of change");
  assert.equal(first[1].amount + rest[1].amount, 40000);
  // Online goes back to the website; Advance and Exchange to the account.
  assert.deepEqual(
    refundBreakdown({ customerId: "c", tenders: [{ type: "Online", amount: 100 }] }, 0, 100, "Cash"),
    [{ type: "Online", amount: 100 }],
  );
  assert.deepEqual(
    refundBreakdown({ customerId: "c", tenders: [{ type: "Advance", amount: 50 }, { type: "Exchange", amount: 50 }] }, 0, 100, "Cash"),
    [{ type: "Credit", amount: 100 }],
  );
  // A walk-in's exchange credit is paid back by the requested method.
  assert.deepEqual(refundBreakdown({ tenders: [{ type: "Exchange", amount: 80 }] }, 0, 80, "Cash"), [{ type: "Cash", amount: 80 }]);
});

test("QA #3: with no refund method requested, each tender goes back by itself (same default as the UI)", () => {
  assert.deepEqual(refundBreakdown({ tenders: [{ type: "UPI", amount: 500 }] }, 0, 500, ""), [{ type: "UPI", amount: 500 }]);
  assert.deepEqual(refundBreakdown({ tenders: [{ type: "Card", amount: 500 }] }, 0, 500, ""), [{ type: "Card", amount: 500 }]);
  assert.deepEqual(
    refundBreakdown({ tenders: [{ type: "Cash", amount: 300 }, { type: "UPI", amount: 200 }] }, 0, 500, ""),
    [{ type: "Cash", amount: 300 }, { type: "UPI", amount: 200 }],
  );
  // An explicit switch to cash still pays everything from the drawer.
  assert.deepEqual(refundBreakdown({ tenders: [{ type: "UPI", amount: 500 }] }, 0, 500, "Cash"), [{ type: "Cash", amount: 500 }]);
  // Nothing on record (old bills): cash.
  assert.deepEqual(refundBreakdown({ tenders: [] }, 0, 500, ""), [{ type: "Cash", amount: 500 }]);
});

test("Money and stock: refunds per tender, exchange till, Tally, kit reservations, job void, serials", async () => {
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
    const get = (path: string, token: string, status = 200) => call(path, undefined, token, status, "GET");
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const manager = await login("manager@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const stockOf = async (productId: string, binId = "bin-a1") =>
      (await get("bootstrap", manager)).stock.find((s: any) => s.productId === productId && s.binId === binId) || { quantity: 0, available: 0, reserved: 0 };
    const balance = async (customerId = "customer-1") => (await get(`customers/${customerId}/summary`, manager)).balance;
    const actor = { id: "user-manager", organizationId: "demo", branchId: "pune", role: "manager", name: "Manager" };
    const drawer = async (shift: any) => (await shiftCashSummaries(db, actor, [shift]))[0].expectedCash;
    const cash = (amount: number) => [{ type: "Cash", amount, confirmed: true }];
    const till = await call("shifts/open", { openingCash: 0 }, cashier);
    const sell = (lines: any[], tenders: any[] = cash(100000000), extra: any = {}, token = cashier) =>
      call("invoices", { transactionId: randomUUID(), shiftId: till.id, lines, tenders, ...extra }, token);
    const brake = [{ productId: "brake", qty: 1, binId: "bin-a1" }];
    const wiper = [{ productId: "wiper", qty: 1, binId: "bin-a1" }];
    const brakePrice = (await sell(brake)).total;
    const wiperPrice = (await sell(wiper)).total;

    // ---------- Exchange by a manager with no shift of their own, on the cashier's till ----------
    const old = await sell(brake);
    const tillBefore = await drawer(till);
    const swapped = await call("invoices", {
      transactionId: randomUUID(), shiftId: till.id, lines: wiper,
      returns: [{ kind: "returnRef", invoiceId: old.id, lineId: old.lines[0].id, qty: 1 }],
      tenders: cash(0), exchangeRefundType: "Cash",
    }, manager);
    const exchangeCredit = (await records(db, "demo", "return", "pune")).find((r) => r.id === swapped.exchange.returnId)!;
    assert.equal(exchangeCredit.shiftId, till.id, "cash back lands on the sale's till");
    assert.deepEqual(exchangeCredit.refunds, [{ type: "Cash", amount: brakePrice - wiperPrice }]);
    assert.deepEqual(swapped.exchange.refunds, exchangeCredit.refunds);
    assert.equal(swapped.exchange.credit - swapped.exchange.applied, swapped.exchange.refund);
    assert.equal(await drawer(till), tillBefore - (brakePrice - wiperPrice));

    // The manager opens a till for the refunds below.
    const own = await call("shifts/open", { openingCash: 0 }, manager);

    // ---------- Credit-sold bill exchanged, then the new bill returned ----------
    const start = await balance();
    const onAccount = await sell(brake, [{ type: "Credit", amount: brakePrice }], { customerId: "customer-1" });
    assert.equal(await balance(), start + brakePrice);
    const replacement = await call("invoices", {
      transactionId: randomUUID(), shiftId: own.id, customerId: "customer-1", lines: brake,
      returns: [{ kind: "returnRef", invoiceId: onAccount.id, lineId: onAccount.lines[0].id, qty: 1 }],
      tenders: cash(0),
    }, manager);
    assert.deepEqual(replacement.tenders.filter((t: any) => t.amount).map((t: any) => [t.type, t.amount]), [["Exchange", brakePrice]]);
    assert.equal(await balance(), start + brakePrice, "still owes for the part they took home");
    let ownBefore = await drawer(own);
    const back = await call(`invoices/${replacement.id}/returns`, {
      transactionId: randomUUID(), reason: "Not needed", refundType: "Cash",
      lines: [{ lineId: replacement.lines[0].id, quantity: 1, disposition: "restock" }],
    }, manager);
    assert.deepEqual(back.refunds, [{ type: "Credit", amount: brakePrice }]);
    assert.equal(back.refundType, "Credit");
    assert.equal(await drawer(own), ownBefore, "no cash out for an exchange credit");
    assert.equal(await balance(), start, "account back where it started");

    // ---------- Mixed cash + credit bill ----------
    const half = Math.floor(brakePrice / 2);
    const mixed = await sell(brake, [{ type: "Cash", amount: half, confirmed: true }, { type: "Credit", amount: brakePrice - half }], { customerId: "customer-1" });
    const selected = { invoiceId: mixed.id, number: mixed.number, lines: [{ lineId: mixed.lines[0].id, quantity: 1 }] };
    const preview = await call("returns/preview", selected, cashier);
    assert.deepEqual(preview.refunds, [{ type: "Cash", amount: half }, { type: "Credit", amount: brakePrice - half }]);
    await call("returns/preview", { ...selected, number: "wrong" }, cashier, 404);
    await call("returns/preview", { ...selected, lines: [{ lineId: mixed.lines[0].id, quantity: 2 }] }, cashier, 400);
    ownBefore = await drawer(own);
    const mixedBack = await call(`invoices/${mixed.id}/returns`, {
      transactionId: randomUUID(), reason: "Wrong part", refundType: "Cash",
      lines: [{ lineId: mixed.lines[0].id, quantity: 1, disposition: "restock" }],
    }, manager);
    assert.deepEqual(mixedBack.refunds, [{ type: "Cash", amount: half }, { type: "Credit", amount: brakePrice - half }]);
    assert.equal(mixedBack.refundType, "Mixed");
    assert.deepEqual(mixedBack.refunds, preview.refunds);
    assert.equal(mixedBack.refundTotal, brakePrice);
    assert.equal(await drawer(own), ownBefore - half);
    assert.equal(await balance(), start);

    // ---------- Online bill returned: nothing leaves the drawer ----------
    // Invoices are immutable, so a website invoice is written as a copy of a counter one.
    const counterBill = await sell(wiper);
    const web = { ...(await getRecord(db, "demo", "invoice", counterBill.id))!, id: "invoice-web-1", number: counterBill.number + "-W",
      transactionId: randomUUID(), channel: "online", tenders: [{ type: "Online", amount: counterBill.total, confirmed: true }], change: 0 };
    await putRecord(db, "demo", "invoice", web, "pune");
    ownBefore = await drawer(own);
    const webBack = await call(`invoices/${web.id}/returns`, {
      transactionId: randomUUID(), reason: "Website return", refundType: "Cash",
      lines: [{ lineId: web.lines[0].id, quantity: 1, disposition: "restock" }],
    }, manager);
    assert.deepEqual(webBack.refunds, [{ type: "Online", amount: web.total }]);
    assert.equal(webBack.refundType, "Online");
    assert.equal(await drawer(own), ownBefore);
    const summary = await shiftSummary(db, actor, own);
    // The exchange credit set against the replacement bill shows as "Exchange".
    assert.deepEqual(summary.refunds, { Exchange: brakePrice, Credit: brakePrice + (brakePrice - half), Cash: half, Online: web.total });
    const tenderReport = await get("reports/tenders", manager);
    const online = (tenderReport.rows || tenderReport).find((r: any) => r.type === "Online");
    assert.equal(online.refunded, web.total);

    // ---------- Tally: balanced vouchers, website and exchange ledgers ----------
    const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata" }).format(new Date());
    const tally = await tallyVouchers(db, actor, { dateFrom: today, dateTo: today, vouchers: "sales" });
    for (const voucher of tally.vouchers)
      assert.equal(voucher.entries.reduce((n, e) => n + e.amount, 0), 0, `${voucher.number} balances`);
    const webVoucher = tally.vouchers.find((v) => v.number === web.number)!;
    assert.ok(webVoucher.entries.some((e) => e.ledger === "Website Collections" && e.amount === web.total));
    assert.ok(!webVoucher.entries.some((e) => e.ledger === "Counter Customer"), "website customer does not owe");
    const exchangeNote = tally.vouchers.find((v) => v.number === exchangeCredit.number)!;
    assert.ok(exchangeNote.entries.some((e) => e.ledger === "Counter Customer" && e.amount === -wiperPrice));
    assert.ok(exchangeNote.entries.some((e) => e.ledger === "Cash" && e.amount === -(brakePrice - wiperPrice)));
    assert.ok(!exchangeNote.entries.some((e) => e.ledger === "Round Off"));
    const mixedNote = tally.vouchers.find((v) => v.number === mixedBack.number)!;
    assert.ok(mixedNote.entries.some((e) => e.ledger === "Cash" && e.amount === -half));
    assert.ok(mixedNote.entries.some((e) => e.ledger === "Arjun Demo" && e.amount === -(brakePrice - half)));
    assert.ok(tally.ledgers.some((l) => l.name === "Website Collections" && l.group === "Current Assets"));

    // ---------- Kits reserve their components ----------
    const kit = await call("products", {
      name: "Brake Kit", sku: "KIT-B", hsnSac: "8708", retailPrice: 250000, taxRate: 2800,
      components: [{ productId: "brake", qty: 1 }, { productId: "brake-fluid", qty: 2 }, { productId: "service", qty: 1 }],
    }, manager);
    const brakeFree = (await stockOf("brake")).available;
    const fluidFree = (await stockOf("brake-fluid")).available;
    const parked = await call("holds", { cart: { lines: [{ productId: kit.id, qty: 1, components: [{ productId: "oil", qty: 99, binId: "bin-a1" }] }] } }, cashier);
    assert.deepEqual(parked.cart.lines[0].components.map((c: any) => [c.productId, c.qty, c.binId]).sort(),
      [["brake", 1, "bin-a1"], ["brake-fluid", 2, "bin-a1"]]);
    assert.equal((await stockOf("brake")).available, brakeFree - 1);
    assert.equal((await stockOf("brake-fluid")).available, fluidFree - 2);
    // An expired hold reserves nothing.
    await putRecord(db, "demo", "hold", { ...(await getRecord(db, "demo", "hold", parked.id))!, expiresAt: "2020-01-01T00:00:00.000Z" }, "pune");
    assert.equal((await stockOf("brake")).available, brakeFree);
    await call(`holds/${parked.id}`, undefined, cashier, 200, "DELETE");

    // A job card with a kit reserves the components until it is billed.
    const job = await call("jobs", { customerId: "customer-1", lines: [{ productId: kit.id, qty: 1 }] }, cashier);
    assert.equal((await stockOf("brake")).available, brakeFree - 1);
    const brakeQty = (await stockOf("brake")).quantity;
    const billed = await call(`jobs/${job.id}/invoice`, {
      transactionId: randomUUID(), shiftId: till.id, tenders: cash(100000000),
    }, cashier);
    assert.deepEqual(billed.lines[0].components.filter((c: any) => c.binId).map((c: any) => [c.productId, c.qty]).sort(),
      [["brake", 1], ["brake-fluid", 2]]);
    assert.equal((await stockOf("brake")).quantity, brakeQty - 1);
    assert.equal((await stockOf("brake")).available, brakeFree - 1, "reservation used by the bill");

    // ---------- Voiding a job's invoice returns the job to "ready" ----------
    const voided = await call(`invoices/${billed.id}/void`, { transactionId: randomUUID(), reason: "Billed wrong customer" }, manager);
    assert.deepEqual(voided.totalRefunds, [{ type: "Cash", amount: voided.totalRefund }]);
    let reopened = (await get("bootstrap", manager)).jobs.find((j: any) => j.id === job.id);
    assert.equal(reopened.status, "ready");
    assert.equal(reopened.invoiceId, null);
    assert.ok(reopened.holdId, "parts reserved again");
    assert.equal((await stockOf("brake")).quantity, brakeQty);
    assert.equal((await stockOf("brake")).available, brakeFree - 1);
    const rebilled = await call(`jobs/${job.id}/invoice`, { transactionId: randomUUID(), shiftId: till.id, tenders: cash(100000000) }, cashier);
    reopened = (await get("bootstrap", manager)).jobs.find((j: any) => j.id === job.id);
    assert.equal(reopened.invoiceId, rebilled.id);
    assert.equal(reopened.status, "delivered");

    // ---------- A restocked serial is back in stock for the warranty lookup ----------
    const battery = await call("products", {
      name: "Battery 45Ah", sku: "BAT-45", hsnSac: "8507", retailPrice: 600000, serialTracked: true, warrantyMonths: 36, universal: true,
    }, manager);
    await db.query("INSERT INTO stock(organization_id,branch_id,product_id,bin_id,quantity) VALUES('demo','pune',$1,'bin-a1',1)", [battery.id]);
    await putRecord(db, "demo", "serial", {
      id: battery.id + ":B1", branchId: "pune", productId: battery.id, serial: "B1", binId: "bin-a1", status: "available",
    }, "pune");
    const batterySale = await sell([{ productId: battery.id, qty: 1, binId: "bin-a1", serials: ["B1"] }], cash(100000000), { customerId: "customer-1" });
    assert.equal((await get("serials/lookup?code=B1", manager)).rows[0].warranty, "in warranty");
    await call(`invoices/${batterySale.id}/returns`, {
      transactionId: randomUUID(), reason: "Changed mind", refundType: "Cash",
      lines: [{ lineId: batterySale.lines[0].id, quantity: 1, disposition: "restock", serials: ["B1"] }],
    }, manager);
    const serial = (await getRecord(db, "demo", "serial", battery.id + ":B1"))!;
    assert.equal(serial.status, "available");
    for (const field of ["invoiceId", "customerId", "vehicleId", "soldAt", "warrantyUntil"]) assert.equal(serial[field], null, field);
    assert.equal(serial.history.length, 1);
    assert.equal(serial.history[0].invoiceId, batterySale.id);
    assert.equal((await get("serials/lookup?code=B1", manager)).rows[0].warranty, "not sold");
  } finally {
    await app.close();
    await db.close();
  }
});
