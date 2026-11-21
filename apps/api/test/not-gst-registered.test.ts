// "Not GST registered": bills carry final prices with no tax, no GSTIN and no GSTR-1.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

test("Not GST registered shop bills final prices without tax", async () => {
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
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const manager = await login("manager@motorline.local");

    // The owner switches the shop to "Not GST registered" (GSTIN on file is not printed).
    await call("settings", { taxScheme: "none", business: { taxRegistrationId: "27ABCDE1234F1Z5", legalName: "Demo", address: "Pune" } }, owner);
    await call("settings", { taxScheme: "bogus" }, owner, 400);
    // Clearing every part's tax needs the not-registered choice; here it is set.
    const oilBefore = await getRecord(db, "demo", "product", "oil");
    assert.equal(oilBefore!.taxRate, 1800);

    const shift = await call("shifts/open", { openingCash: 0 }, manager);
    const sell = (lines: any[]) =>
      call("invoices", { transactionId: randomUUID(), shiftId: shift.id, lines, tenders: [{ type: "Cash", amount: 100000000, confirmed: true }] }, manager);

    // Even a part still carrying 18% sells at its price with no tax.
    const price = oilBefore!.retailPrice;
    const invoice = await sell([{ productId: "oil", qty: 2, binId: "bin-a1" }]);
    assert.equal(invoice.taxScheme, "none");
    assert.equal(invoice.tax, 0);
    assert.equal(invoice.total, price * 2);
    assert.deepEqual(invoice.taxComponents, []);
    assert.equal(invoice.lines[0].taxRate, 0);
    assert.deepEqual(invoice.lines[0].taxComponents, []);
    assert.equal(invoice.business.taxRegistrationId, undefined);
    assert.doesNotMatch(JSON.stringify(invoice), /CGST|SGST|IGST|27ABCDE1234F1Z5/);

    // One action sets every existing part's tax to 0.
    await call("settings", { zeroProductTax: true }, owner);
    for (const product of await records(db, "demo", "product")) assert.equal(product.taxRate || 0, 0);

    // New parts default to no tax and need no HSN.
    const created = await call("products", { name: "Plain bulb", retailPrice: 15000, cost: 9000 }, owner);
    assert.equal(created.taxRate, 0);

    // Credit notes carry no tax either.
    const credit = await call(`invoices/${invoice.id}/returns`, {
      transactionId: randomUUID(),
      reason: "Customer returned",
      refundType: "Cash",
      lines: [{ lineId: invoice.lines[0].id, quantity: 1, disposition: "restock" }],
    }, manager);
    assert.equal(credit.tax || 0, 0);
    assert.equal(credit.total, price);
    assert.doesNotMatch(JSON.stringify(credit), /CGST|SGST|IGST/);

    // There is no GSTR-1 for a shop that is not registered.
    const day = new Date().toISOString().slice(0, 10);
    const refused = await call(`exports/gstr1?dateFrom=${day}&dateTo=${day}`, undefined, owner, 409, "GET");
    assert.match(refused.error || refused.message, /not GST registered/);

    // Switching back to GST makes "zero every part" refuse.
    await call("settings", { taxScheme: "general" }, owner);
    await call("settings", { zeroProductTax: true }, owner, 400);
  } finally {
    await app.close();
    await db.close();
  }
});
