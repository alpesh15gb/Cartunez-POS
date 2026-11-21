// Fresh launch: resetForLaunch clears the test data and keeps the shop's set-up.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { resetCounts, resetForLaunch, KEPT_KINDS } from "../src/reset.js";

test("Fresh-launch reset keeps the set-up and clears everything else", async () => {
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
    const login = async (email: string, status = 200) =>
      (await call("auth/login", { email, password: "MotorlineDemo123!" }, undefined, status)).token;
    let owner = await login("owner@motorline.local");
    const manager = await login("manager@motorline.local");

    // ---------- Test data: a sale, a credit note, an old balance, a website connection ----------
    await call("settings", {
      business: { tradingName: "Cartunez", legalName: "Cartunez Auto", address: "Pune", phone: "9000000000" },
      invoicePrefix: "CT",
    }, owner);
    const shift = await call("shifts/open", { openingCash: 0 }, manager);
    const invoice = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: "oil", qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 100000000, confirmed: true }],
      customerId: "customer-1",
    }, manager);
    await call(`invoices/${invoice.id}/returns`, {
      transactionId: randomUUID(), reason: "Test", refundType: "Cash",
      lines: [{ lineId: invoice.lines[0].id, quantity: 1, disposition: "restock" }],
    }, manager);
    const customer = (await getRecord(db, "demo", "customer", "customer-1"))!;
    await putRecord(db, "demo", "customer", { ...customer, openingBalance: 50000, openingDate: "2026-01-01", vehicle: { make: "Demo" } });
    const settings = (await getRecord(db, "demo", "settings", "settings"))!;
    await putRecord(db, "demo", "settings", {
      ...settings,
      integrations: { magento: { enabled: true, baseUrl: "https://shop.example.test", tokenSet: true, branchId: "pune", connectedAt: "2026-01-01T00:00:00Z" } },
    });
    await putRecord(db, "demo", "integrationSecret", { id: "magento", token: "test-token" });
    await putRecord(db, "demo", "onlineListing", { id: "oil", published: true, magentoId: 42 });
    await putRecord(db, "demo", "magentoCategory", { id: "cat-1", magentoId: 7 });

    // ---------- What will happen ----------
    const counts = await resetCounts(db, "demo");
    assert.ok(counts.delete.product > 0);
    assert.equal(counts.delete.invoice, 1);
    assert.equal(counts.delete.return, 1);
    assert.ok(counts.delete["user (staff)"] > 0);
    assert.ok(counts.delete["table stock_ledger"] > 0);
    assert.equal(counts.keep["user (owner)"], 1);
    assert.equal(counts.keep.organization, 1);

    const result = await resetForLaunch(db, "demo");
    assert.deepEqual(result.deleted, counts.delete);

    // ---------- What remains ----------
    const kinds = (await db.query("SELECT kind, count(*)::int AS n FROM records WHERE organization_id='demo' GROUP BY kind")).rows;
    for (const row of kinds) assert.ok([...KEPT_KINDS, "audit"].includes(row.kind), `left behind: ${row.kind}`);
    assert.equal(kinds.find((row) => row.kind === "audit")?.n, 1);
    const users = await records(db, "demo", "user");
    assert.deepEqual(users.map((user) => user.role), ["owner"]);
    for (const table of ["stock", "stock_ledger", "transactions"])
      assert.equal(Number((await db.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n), 0, table);
    assert.equal((await records(db, "demo", "branch")).length, 2);
    assert.ok((await records(db, "demo", "location")).length > 0);
    assert.equal((await records(db, "demo", "supplier")).length, 1);
    const kept = (await getRecord(db, "demo", "customer", "customer-1"))!;
    assert.equal(kept.name, customer.name);
    assert.equal(kept.openingBalance, 0);
    assert.equal(kept.vehicle, null);
    assert.equal(await getRecord(db, "demo", "onlineListing", "oil"), undefined);

    const fresh = (await getRecord(db, "demo", "settings", "settings"))!;
    assert.equal(fresh.taxScheme, "none");
    assert.equal(fresh.nextInvoice, 1);
    assert.equal(fresh.nextCreditNote, 1);
    assert.equal(fresh.nextEstimate, 1);
    assert.equal(fresh.nextJob, 1);
    assert.equal(fresh.business.tradingName, "Cartunez");
    assert.equal(fresh.business.address, "Pune");
    assert.equal(fresh.business.taxRegistrationId, "");
    assert.equal(fresh.invoicePrefix, "CT");
    assert.equal(fresh.integrations.magento.baseUrl, "https://shop.example.test");
    assert.notEqual(fresh.integrations.magento.connectedAt, "2026-01-01T00:00:00Z");
    assert.equal((await getRecord(db, "demo", "integrationSecret", "magento"))!.token, "test-token");

    // The append-only protection is back on after the reset.
    await assert.rejects(db.query("DELETE FROM records WHERE kind='audit'"), /immutable/);

    // ---------- The shop works from a clean start ----------
    await login("manager@motorline.local", 401);
    owner = await login("owner@motorline.local");
    const boot = await call("bootstrap", undefined, owner, 200, "GET");
    assert.equal(boot.products.length, 0);
    assert.equal(boot.invoices.length, 0);
    const part = await call("products", { name: "Launch part", retailPrice: 25000 }, owner);
    assert.equal(part.taxRate, 0);
    const shift2 = await call("shifts/open", { openingCash: 0 }, owner);
    const first = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift2.id,
      lines: [{ productId: part.id, qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 25000, confirmed: true }],
    }, owner);
    assert.equal(first.number, "CT-PUNE-1");
    assert.equal(first.total, 25000);
    assert.equal(first.tax, 0);

    // A reset without the identity clears the shop name and prefixes too.
    await resetForLaunch(db, "demo", { keepIdentity: false });
    const blank = (await getRecord(db, "demo", "settings", "settings"))!;
    assert.equal(blank.business.address, "");
    assert.equal(blank.invoicePrefix, "INV");
  } finally {
    await app.close();
    await db.close();
  }
});
