// WS-B: returns with dispositions, instant exchange, credit limit and customer advances.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { shiftCashSummaries } from "../src/shift-cash.js";

test("Returns, exchanges, credit limit and advances", async () => {
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
    const boot = (token: string) => get("bootstrap", token);
    const stockOf = async (productId: string, binId: string) =>
      (await boot(manager)).stock.filter((s: any) => s.productId === productId && s.binId === binId).reduce((n: number, s: any) => n + s.quantity, 0);
    const approval = async (action: string, transactionId: string, bound: any = {}) =>
      (await call("approvals", { action, transactionId, reason: "Test", ...bound }, manager)).id;
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    await call("shifts/open", { openingCash: 0 }, manager);
    const cash = (amount: number) => [{ type: "Cash", amount, confirmed: true }];
    const sell = (lines: any[], tenders: any[] = cash(100000000), extra: any = {}, token = cashier) =>
      call("invoices", { transactionId: randomUUID(), shiftId: shift.id, lines, tenders, ...extra }, token);

    // ---------- Lookup and dispositions ----------
    const first = await sell([
      { productId: "oil", qty: 2, binId: "bin-a1" },
      { productId: "filter", qty: 1, binId: "bin-a1" },
      { productId: "wiper", qty: 1, binId: "bin-a1" },
    ], cash(100000000), { customerId: "customer-1" });
    const byNumber = await get(`returns/lookup?q=${encodeURIComponent(first.number)}`, cashier);
    assert.equal(byNumber[0].id, first.id);
    assert.equal(byNumber[0].lines.find((l: any) => l.productId === "oil").returnableQty, 2);
    const byPhone = await get("returns/lookup?q=9000000101", cashier);
    assert.ok(byPhone.some((i: any) => i.id === first.id));
    await get("returns/lookup?q=x", cashier, 400);

    const line = (productId: string, invoice = first) => invoice.lines.find((l: any) => l.productId === productId);
    const damagedBefore = await stockOf("oil", "bin-damaged");
    const sellableBefore = await stockOf("filter", "bin-a1");
    const mixed = await call(`invoices/${first.id}/returns`, {
      transactionId: randomUUID(),
      reason: "Customer returned",
      refundType: "Cash",
      lines: [
        { lineId: line("oil").id, quantity: 1, disposition: "damaged" },
        { lineId: line("filter").id, quantity: 1, disposition: "restock" },
        { lineId: line("wiper").id, quantity: 1, disposition: "rma" },
      ],
    }, manager);
    assert.equal(mixed.condition, "mixed");
    assert.equal(await stockOf("oil", "bin-damaged"), damagedBefore + 1);
    assert.equal(await stockOf("filter", "bin-a1"), sellableBefore + 1);
    assert.equal(await stockOf("wiper", "bin-warranty"), 1);
    assert.equal(mixed.warrantyClaimIds.length, 1);
    const claim = (await boot(manager)).warrantyClaims.find((c: any) => c.id === mixed.warrantyClaimIds[0]);
    assert.equal(claim.supplierId, "supplier-1");
    assert.equal(claim.returnId, mixed.id);
    assert.equal(claim.status, "open");
    // The claim can be moved on through the existing warranty route.
    await call("warranty-claims", { id: claim.id, returnId: mixed.id, supplierId: "supplier-1", reason: claim.reason, status: "sent" }, manager);
    const after = await get(`returns/lookup?q=${encodeURIComponent(first.number)}`, cashier);
    assert.equal(after[0].lines.find((l: any) => l.productId === "oil").returnableQty, 1);
    assert.equal(after[0].lines.find((l: any) => l.productId === "wiper").returnableQty, 0);

    // ---------- Instant exchange: pay the difference ----------
    const old = await sell([{ productId: "wiper", qty: 1, binId: "bin-a1" }]);
    const wiperStock = await stockOf("wiper", "bin-a1");
    const brakeStock = await stockOf("brake", "bin-a1");
    const brakePrice = (await sell([{ productId: "brake", qty: 1, binId: "bin-a1" }])).total;
    const exchangeId = randomUUID();
    const exchangeBody = (tenders: any[], extra: any = {}) => ({
      transactionId: exchangeId,
      shiftId: shift.id,
      lines: [
        { productId: "brake", qty: 1, binId: "bin-a1" },
        { kind: "returnRef", invoiceId: old.id, lineId: old.lines[0].id, qty: 1, disposition: "restock" },
      ],
      tenders,
      ...extra,
    });
    // Cashier needs a manager's return approval.
    await call("invoices", exchangeBody(cash(brakePrice - old.total)), cashier, 403);
    const returnApprovalId = await approval("return", exchangeId, { subjectId: old.id });
    // Not enough paid: everything rolls back (no credit note, no stock change).
    const creditsBefore = (await records(db, "demo", "return", "pune")).length;
    await call("invoices", exchangeBody(cash(brakePrice - old.total - 100), { returnApprovalId }), cashier, 400);
    assert.equal((await records(db, "demo", "return", "pune")).length, creditsBefore);
    assert.equal(await stockOf("wiper", "bin-a1"), wiperStock);
    const swapped = await call("invoices", exchangeBody(cash(brakePrice - old.total), { returnApprovalId }), cashier);
    assert.equal(swapped.total, brakePrice);
    assert.equal(swapped.exchange.credit, old.total);
    assert.equal(swapped.exchange.applied, old.total);
    assert.equal(swapped.exchange.refund, 0);
    assert.deepEqual(swapped.tenders.map((t: any) => t.type).sort(), ["Cash", "Exchange"]);
    assert.equal(swapped.lines.length, 1);
    assert.equal(await stockOf("wiper", "bin-a1"), wiperStock + 1);
    assert.equal(await stockOf("brake", "bin-a1"), brakeStock - 2);
    const credit = (await records(db, "demo", "return", "pune")).find((r) => r.id === swapped.exchange.returnId)!;
    assert.equal(credit.invoiceId, old.id);
    assert.equal(credit.transactionId, swapped.transactionId);
    assert.equal(credit.refundType, "Exchange");
    assert.equal(credit.refundTotal, 0);
    // Retrying the same checkout returns the same invoice.
    assert.equal((await call("invoices", exchangeBody(cash(brakePrice - old.total), { returnApprovalId }), cashier)).id, swapped.id);
    // The wiper on that bill is now fully returned.
    await call("invoices", {
      ...exchangeBody(cash(brakePrice), { returnApprovalId: await approval("return", "x", { subjectId: old.id }) }),
      transactionId: "x",
    }, cashier, 400);

    // ---------- Exchange for something cheaper: cash back through the shift ----------
    const big = await sell([{ productId: "brake", qty: 1, binId: "bin-a1" }]);
    const cheapId = randomUUID();
    const cashierActor = { id: "user-cashier", organizationId: "demo", branchId: "pune", role: "cashier", name: "Cashier" };
    const drawer = async () => (await shiftCashSummaries(db, cashierActor, [shift as any]))[0].expectedCash;
    const drawerBefore = await drawer();
    const cheap = await call("invoices", {
      transactionId: cheapId,
      shiftId: shift.id,
      lines: [{ productId: "wiper", qty: 1, binId: "bin-a1" }],
      returns: [{ kind: "returnRef", invoiceId: big.id, lineId: big.lines[0].id, qty: 1 }],
      tenders: cash(0),
      exchangeRefundType: "Cash",
      returnApprovalId: await approval("return", cheapId, { subjectId: big.id }),
    }, cashier);
    assert.equal(cheap.exchange.applied, cheap.total);
    assert.equal(cheap.exchange.refund, big.total - cheap.total);
    assert.equal(cheap.exchange.refundType, "Cash");
    assert.notEqual(cheap.exchange.creditNoteNumber, swapped.exchange.creditNoteNumber);
    // Only the excess left the drawer: the rest was set against the new bill.
    assert.equal(await drawer(), drawerBefore - (big.total - cheap.total));
    // Exchange credit cannot be sent by the register itself.
    await sell([{ productId: "wiper", qty: 1, binId: "bin-a1" }], [{ type: "Exchange", amount: 100, confirmed: true }, ...cash(100000000)], {}, cashier)
      .then(() => assert.fail("should refuse"), () => undefined);

    // ---------- Credit limit ----------
    const buyer = await call("customers", { name: "Ravi Garage", phone: "9876500001" }, cashier);
    await call(`customers/${buyer.id}/credit-limit`, { creditLimit: 100000 }, cashier, 403);
    const limited = await call(`customers/${buyer.id}/credit-limit`, { creditLimit: 100000 }, manager);
    assert.equal(limited.creditLimit, 100000);
    // An ordinary edit keeps the limit.
    assert.equal((await call("customers", { ...limited, phone: "9876500002" }, cashier)).creditLimit, 100000);
    const onCredit = (transactionId: string, extra: any = {}, token = cashier) =>
      call("invoices", {
        transactionId, shiftId: shift.id, customerId: buyer.id,
        lines: [{ productId: "brake", qty: 1, binId: "bin-a1" }],
        tenders: [{ type: "Credit", amount: brakePrice, confirmed: true }],
        ...extra,
      }, token, extra.status ?? 200);
    const blockedId = randomUUID();
    const blocked = await onCredit(blockedId, { status: 403 });
    assert.match(blocked.error, /above their credit limit/);
    const overridden = await onCredit(blockedId, { creditApprovalId: await approval("credit-limit", blockedId, { subjectId: "9876500002", amount: brakePrice }) });
    assert.equal(overridden.creditLimitOverride.limit, 100000);
    // Within the limit no approval is needed.
    await call(`customers/${buyer.id}/credit-limit`, { creditLimit: 10000000 }, manager);
    await onCredit(randomUUID());

    // ---------- Advances ----------
    const booker = await call("customers", { name: "Neha Booking", phone: "9876500003" }, cashier);
    await call(`customers/${booker.id}/advances`, { amount: 0, mode: "Cash" }, cashier, 400);
    const advance = await call(`customers/${booker.id}/advances`, { amount: 300000, mode: "Cash", notes: "Seat covers on order" }, cashier);
    assert.equal(advance.shiftId, shift.id);
    assert.equal(advance.advance, true);
    let summary = await get(`customers/${booker.id}/summary`, cashier);
    assert.equal(summary.balance, -300000);
    assert.equal(summary.availableAdvance, 300000);
    assert.match(summary.entries[0].reference, /^Advance/);
    // Using more than is held is refused.
    await sell([{ productId: "brake", qty: 2, binId: "bin-a1" }], [{ type: "Advance", amount: 300001 }, ...cash(100000000)], { customerId: booker.id }, cashier)
      .then(() => assert.fail("should refuse"), () => undefined);
    const used = await sell(
      [{ productId: "wiper", qty: 1, binId: "bin-a1" }],
      [{ type: "Advance", amount: 50000 }, ...cash(100000000)],
      { customerId: booker.id },
    );
    assert.equal(used.advanceApplied, 50000);
    summary = await get(`customers/${booker.id}/summary`, cashier);
    assert.equal(summary.balance, -250000);
    assert.equal(summary.invoices[0].advanceApplied, 50000);
    assert.ok(summary.entries.some((e: any) => e.note === "Advance used" && e.debit === 50000));
    // Giving an advance back needs a manager.
    await call(`customers/${booker.id}/advances/refund`, { amount: 10000, mode: "Cash", reason: "Cancelled" }, cashier, 403);
    const refundId = randomUUID();
    await call(`customers/${booker.id}/advances/refund`, {
      transactionId: refundId, amount: 10000, mode: "Cash", reason: "Cancelled",
      approvalId: await approval("advance-refund", refundId, { subjectId: booker.id, amount: 10000 }),
    }, cashier);
    await call(`customers/${booker.id}/advances/refund`, { amount: 9999999, mode: "Cash", reason: "Too much" }, manager, 409);
    await call(`customers/${booker.id}/advances/refund`, { amount: 240000, mode: "UPI", reason: "Cancelled" }, manager);
    assert.equal((await get(`customers/${booker.id}/summary`, cashier)).balance, 0);

    // ---------- Store credit from a return, used later ----------
    const credited = await call(`invoices/${used.id}/returns`, {
      transactionId: randomUUID(), reason: "Wrong size", refundType: "Credit",
      lines: [{ lineId: used.lines[0].id, quantity: 1, disposition: "restock" }],
    }, manager);
    assert.equal((await get(`customers/${booker.id}/summary`, cashier)).availableAdvance, credited.total);

    // ---------- Collections ----------
    const owed = await get("collections", cashier);
    const row = owed.rows.find((r: any) => r.customerId === buyer.id);
    assert.equal(row.balance, brakePrice * 2);
    assert.equal(row.dueBills, 2);
    assert.equal(owed.rows.some((r: any) => r.customerId === booker.id), false);
    const due = (await get(`customers/${buyer.id}/summary`, cashier)).dueBills;
    assert.equal(due.length, 2);
    assert.equal(due.reduce((n: number, b: any) => n + b.due, 0), brakePrice * 2);
    // A part payment settles the oldest bill first.
    await call("party-payments", { partyKind: "customer", partyId: buyer.id, amount: brakePrice, mode: "UPI" }, cashier);
    const left = (await get(`customers/${buyer.id}/summary`, cashier)).dueBills;
    assert.equal(left.length, 1);
    assert.equal(left[0].invoiceId, (await records(db, "demo", "invoice", "pune")).filter((i) => i.customerId === buyer.id).at(-1)!.id);
  } finally {
    await app.close();
  }
});
