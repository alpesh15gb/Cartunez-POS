import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

test("drawer cash follows the shift, preserves the journal and reconciles separately from sales", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    async function call(path: string, token: string, body?: any, status = 200) {
      const response = await app.inject({
        method: body === undefined ? "GET" : "POST", url: "/api/v1/" + path, payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(response.statusCode, status, path + ": " + response.body);
      return response.json();
    }
    const login = async (role: string, branchId = "pune") => (await call("auth/login", "", {
      email: role + "@motorline.local", password: "MotorlineDemo123!", branchId,
    })).token;
    const owner = await login("owner");
    const cashier = await login("cashier");
    const otherBranch = await login("owner", "mumbai");
    const inventory = await login("inventory");
    const shift = await call("shifts/open", owner, { openingCash: 10000 });
    const path = "shifts/" + shift.id + "/cash-movements";
    const float = { transactionId: randomUUID(), direction: "in", amount: 2500, reason: "Change float" };
    const posted = await call(path, owner, float);
    assert.equal((await call(path, owner, float)).id, posted.id);
    await call(path, owner, { ...float, amount: 2000 }, 409);
    await call(path, cashier, float, 403);
    await call(path, otherBranch, float, 404);
    await call(path, inventory, float, 403);
    for (const invalid of [{ amount: 0 }, { amount: 1.5 }, { reason: " " }, { direction: "swap" }, { transactionId: "" }]) {
      await call(path, owner, { ...float, transactionId: randomUUID(), ...invalid }, 400);
    }
    await call(path, owner, { transactionId: randomUUID(), direction: "out", amount: 1000, reason: "Safe drop" });

    const service = await call("products", owner, { name: "Test service", sku: "CASH-TEST", brand: "Audit",
      category: "Service", unit: "Job", retailPrice: 10000, type: "service", taxRate: 0 });
    const sale = await call("invoices", owner, {
      transactionId: randomUUID(), shiftId: shift.id, lines: [{ productId: service.id, qty: 2 }],
      tenders: [{ type: "Cash", amount: 22000, confirmed: true }],
    });
    assert.equal(sale.change, 2000);
    await call("invoices/" + sale.id + "/returns", owner, {
      transactionId: randomUUID(), condition: "sellable", reason: "One service cancelled", refundType: "Cash",
      lines: [{ lineId: sale.lines[0].id, quantity: 1 }],
    });
    const shiftReport = await call("reports/shifts", owner);
    const row = shiftReport.rows.find((s: any) => s.id === shift.id);
    assert.deepEqual([row.cashSales, row.cashRefunds, row.cashIn, row.cashOut, row.expectedCash],
      [20000, 10000, 2500, 1000, 21500]);
    assert.equal(shiftReport.totals.expectedCash, 21500);
    assert.equal((await call("reports/tenders", owner)).totals.net, 10000);
    const journal = await call("reports/cash-movements", owner);
    assert.deepEqual(journal.totals, { cashIn: 2500, cashOut: 1000, netMovement: 1500 });
    assert.equal((await call("reports/cash-movements", otherBranch)).rows.length, 0);
    const cashierHome = await call("bootstrap", cashier);
    assert.equal(cashierHome.cashMovements.length, 0);
    assert.ok(!cashierHome.shifts.some((s: any) => s.id === shift.id));
    const inventoryHome = await call("bootstrap", inventory);
    assert.equal(inventoryHome.shifts.length, 0);
    assert.ok(!inventoryHome.audit.some((entry: any) => entry.subject === posted.id));
    await call("reports/cash-movements", inventory, undefined, 403);

    const closed = await call("shifts/" + shift.id + "/close", owner, { countedCash: 21600 });
    assert.equal(closed.expectedCash, 21500);
    assert.equal(closed.variance, 100);
    assert.equal((await call(path, owner, float)).id, posted.id);
    await call(path, owner, { ...float, transactionId: randomUUID() }, 409);
    await assert.rejects(db.query("UPDATE records SET data='{}' WHERE kind='cashMovement' AND id=$1", [posted.id]));
    await assert.rejects(db.query("DELETE FROM records WHERE kind='cashMovement' AND id=$1", [posted.id]));
    const newShift = await call("shifts/open", cashier, { openingCash: 0 });
    await call("shifts/" + newShift.id + "/cash-movements", cashier, { ...float, transactionId: randomUUID() });
    assert.equal((await call("bootstrap", cashier)).cashMovements.length, 1);
  } finally {
    await app.close();
    await db.close();
  }
});
