import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { fail, id } from "../src/domain.js";
import { registerSaleHook, saleHooks } from "../src/sale-pipeline.js";
import { lineKind, invoiceChannel } from "../src/sale-types.js";
import { nextNumber } from "../src/number-series.js";

test("Checkout pipeline: hooks, staff on lines, Advance tender, number series", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db, {});
  try {
    const call = async (path: string, body: any, token?: string, status = 200) => {
      const response = await app.inject({
        method: "POST",
        url: "/api/v1/" + path,
        payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const cashier = (await call("auth/login", { email: "cashier@motorline.local", password: "MotorlineDemo123!" })).token;
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    const sale = (lines: any[], tenders: any[] = [{ type: "Cash", amount: 10000000, confirmed: true }]) => ({
      transactionId: randomUUID(),
      shiftId: shift.id,
      lines,
      tenders,
    });
    const oil = { productId: "oil", qty: 1, binId: "bin-a1" };

    // Built-in behaviour is registered as ordered hooks.
    // (Feature hooks from other modules, such as WS-B's "ws-b-*", sit among them.)
    assert.deepEqual(saleHooks().map((hook) => hook.name).filter((name) => !name.startsWith("ws-")), [
      "account-tender-gate", "line-staff", "credit-tender", "tender-rules",
      "customer-check", "stock-and-serials", "release-hold", "audit",
      "online-channel", // WS-E
    ]);

    // A plain sale carries none of the new optional fields.
    const plain = await call("invoices", sale([oil]), cashier);
    assert.equal(plain.channel, undefined);
    assert.equal(plain.lines[0].staffId, undefined);
    assert.equal(invoiceChannel(plain), "counter");
    assert.equal(lineKind(plain.lines[0]), "part");

    // Staff who sold/fitted the line is recorded; unknown staff is refused.
    const withStaff = await call("invoices", sale([{ ...oil, staffId: "user-manager" }]), cashier);
    assert.equal(withStaff.lines[0].staffId, "user-manager");
    const refused = await call("invoices", sale([{ ...oil, staffId: "user-nobody" }]), cashier, 400);
    assert.match(refused.error || refused.message, /staff member/);

    // Advance is enabled by WS-B's hooks/advance.ts: it needs a customer with money held.
    const advance = await call("invoices", sale([oil], [{ type: "Advance", amount: 10000000, confirmed: true }]), cashier, 400);
    assert.match(advance.error || advance.message, /customer before paying from their advance/);

    // A hook can validate lines and add lines before totals.
    const remove = registerSaleHook({
      name: "test-labour",
      validateLine(_ctx, input) {
        if (input.qty > 5) fail("Test hook: at most five per line.");
      },
      expandLines(ctx) {
        const first = ctx.lines[0];
        ctx.lines.push({
          ...first,
          id: id("line"),
          productId: "service",
          sku: "ML-SERVICE-01",
          name: "Fitting labour",
          type: "service",
          kind: "labour",
          qty: 1,
          serials: [],
          unitPrice: 10000,
          cost: 0,
          coreCharge: 0,
          subtotal: 10000,
        });
      },
    }, { before: "audit" });
    try {
      await call("invoices", sale([{ ...oil, qty: 6 }]), cashier, 400);
      const expanded = await call("invoices", sale([oil]), cashier);
      assert.equal(expanded.lines.length, 2);
      assert.equal(lineKind(expanded.lines[1]), "labour");
      assert.equal(expanded.subtotal, plain.subtotal + 10000);
      assert.equal(expanded.total, plain.total + 11800);
    } finally {
      remove();
    }
    assert.equal(saleHooks().some((hook) => hook.name === "test-labour"), false);
    // With the hook gone, checkout is back to the built-in behaviour.
    const after = await call("invoices", sale([oil]), cashier);
    assert.equal(after.lines.length, 1);
    assert.equal(after.total, plain.total);

    // Number series: defaults for an install that has never used them, then a sequence.
    const actor = { id: "user-manager", organizationId: "demo", branchId: "pune", role: "manager", name: "Manager" };
    const before = await getRecord(db, "demo", "settings", "settings");
    assert.equal(before!.nextEstimate, undefined);
    const taken = await db.transaction(async (tx) => [
      await nextNumber(tx, actor, "estimate"),
      await nextNumber(tx, actor, "estimate"),
      await nextNumber(tx, actor, "job"),
    ]);
    assert.deepEqual(taken, [
      { number: 1, display: "EST-PUNE-1" },
      { number: 2, display: "EST-PUNE-2" },
      { number: 1, display: "JOB-PUNE-1" },
    ]);
    const stored = (await getRecord(db, "demo", "settings", "settings"))!;
    assert.equal(stored.nextEstimate, 3);
    assert.equal(stored.nextJob, 2);
    assert.equal(stored.estimatePrefix, "EST");
    // Invoice numbering is unaffected.
    assert.equal(stored.nextInvoice, before!.nextInvoice);
  } finally {
    await app.close();
  }
});
