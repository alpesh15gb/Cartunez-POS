import { test } from "node:test";
import assert from "node:assert/strict";
import { connectDatabase, migrate, putRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

test("compares branch receipt captures to gross INR provider entries by exact reference and IST day", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    async function login(role: string, branchId = "pune") {
      const response = await app.inject({ method: "POST", url: "/api/v1/auth/login", payload: {
        email: role + "@motorline.local", password: "MotorlineDemo123!", branchId,
      } });
      assert.equal(response.statusCode, 200);
      return response.json().token;
    }
    const card = (reference: string, amount = 10000, type = "Card") => ({ reference, amount, type, confirmed: true });
    async function invoice(id: string, createdAt: string, tenders: any[], branch = "pune") {
      await putRecord(db, "demo", "invoice", { id, number: id, currency: "INR", createdAt, tenders }, branch);
    }
    await invoice("first", "2026-01-01T18:30:00Z", [card("001", 10001), card("001", 101, "UPI"),
      card("dup"), card("dup"), card("date"), card("amount"), card("amount-date"), card("missing"),
      card(""), card("Case"), card("Cash", 5000, "Cash")]);
    await invoice("last", "2026-01-03T18:29:59.999Z", [card("last", 1)]);
    await invoice("before", "2026-01-01T18:29:59.999Z", [card("before")]);
    await invoice("after", "2026-01-03T18:30:00.000Z", [card("after")]);
    await invoice("other-store", "2026-01-02T00:00:00Z", [card("other")], "mumbai");
    const csv = [
      "date,type,reference,gross_inr",
      "2026-01-02,Card,001,100.01", "2026-01-02,UPI,001,1.01", "2026-01-02,Card,dup,100",
      "2026-01-02,Card,dup,100", "2026-01-03,Card,date,100", "2026-01-02,Card,amount,9.5",
      "2026-01-03,Card,amount-date,0.01", "2026-01-03,Card,last,0.01",
      "2026-01-02,Card,case,100", '2026-01-02,Card,"provider, only",10', "2026-01-04,Card,after,100",
    ].join("\r\n");
    const payload = { branchId: "pune", from: "2026-01-02", to: "2026-01-03", csv };
    const owner = await login("owner");
    async function compare(token: string, override = {}, status = 200) {
      const response = await app.inject({ method: "POST", url: "/api/v1/reports/tenders/compare",
        headers: { authorization: "Bearer " + token }, payload: { ...payload, ...override } });
      assert.equal(response.statusCode, status, response.body);
      return response.json();
    }
    const result = await compare(owner);
    assert.deepEqual([result.posCount, result.statementCount, result.matched, result.excluded], [11, 10, 3, 1]);
    const entries = (type: string, reference: string) =>
      result.rows.find((r: any) => r.type === type && r.reference === reference);
    assert.equal(entries("Card", "001").status, "Matched");
    assert.equal(entries("UPI", "001").status, "Matched");
    assert.equal(entries("Card", "last").pos[0].date, "2026-01-03");
    assert.equal(entries("Card", "case").status, "Missing in POS");
    assert.equal(entries("Card", "Case").status, "Missing on statement");
    assert.equal(entries("Card", "dup").status, "Ambiguous reference");
    assert.equal(entries("Card", "").status, "POS reference missing");
    assert.equal(entries("Card", "amount-date").status, "Amount and date differ");
    assert.equal(entries("Card", "date").status, "Date differs");
    assert.equal(entries("Card", "amount").status, "Amount differs");
    assert.equal(entries("Card", "provider, only").status, "Missing in POS");
    assert.deepEqual(entries("Card", "001").pos, [{ date: "2026-01-02", amount: 10001, document: "first" }]);
    assert.deepEqual([result.posGross, result.statementGross, result.difference], [90103, 52054, -38049]);
    const upi = await compare(owner, { type: "UPI" });
    assert.equal(upi.matched, 1);
    assert.equal(upi.posCount, 1);
    assert.equal(upi.statementCount, 1);
    assert.equal(upi.excluded, 10);
    assert.equal((await compare(await login("manager"))).matched, 3);
    await compare(await login("cashier"), {}, 403);
    await compare(await login("inventory"), {}, 403);
    await compare(await login("owner", "mumbai"), {}, 403);
    await compare(owner, { from: "2026-02-30" }, 400);
    await compare(owner, { type: "Cash" }, 400);
    for (const invalid of ["wrong,headers", "2026-02-30,Card,REF,10", "2026-01-02,UPI,,10",
      "2026-01-02,Card,REF,0", "2026-01-02,Card,REF,-15", "2026-01-02,Card,REF,1.001"]) {
      await compare(owner, { csv: "date,type,reference,gross_inr\n" + invalid }, 400);
    }
    const headersOnly = await compare(owner, { csv: "reference,date,gross_inr,type\n" });
    assert.equal(headersOnly.statementCount, 0);
    assert.equal(headersOnly.posGross, result.posGross);
    await putRecord(db, "demo", "settings", { id: "settings", currency: "USD" });
    await compare(owner, {}, 400);
  } finally {
    await app.close();
    await db.close();
  }
});
