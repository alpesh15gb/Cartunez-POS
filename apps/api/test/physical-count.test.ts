import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, getRecord, migrate, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

test("physical counts detect intervening sales, preserve reservations and require manager review", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    async function call(path: string, token: string, body?: any, status = 200) {
      const response = await app.inject({ method: body ? "POST" : "GET", url: "/api/v1/" + path,
        headers: token ? { authorization: "Bearer " + token } : {}, payload: body });
      assert.equal(response.statusCode, status, path + " " + response.body);
      return response.json();
    }
    const login = async (role: string, branchId = "pune") => (await call("auth/login", "", {
      email: role + "@motorline.local", password: "MotorlineDemo123!", branchId })).token;
    const owner = await login("owner"), manager = await login("manager"), staff = await login("inventory");
    const cashier = await login("cashier"), mumbai = await login("owner", "mumbai");
    const part = { productId: "oil", binId: "bin-a1" };
    const start = (who = staff, where = part) => call("inventory/count/start", who, { ...where, transactionId: randomUUID() });
    const submit = (countId: string, counted: number, serials: string[] = [], status = 200) => call("inventory/count/submit", staff,
      { countId, transactionId: randomUUID(), counted, serials, reason: "Cycle count" }, status);
    const confirm = (countId: string, who = manager, status = 200, transactionId = randomUUID()) =>
      call("inventory/count", who, { countId, transactionId }, status);
    const onHand = async (product = "oil") => Number((await db.query(
      "SELECT quantity FROM stock WHERE branch_id='pune' AND product_id=$1 AND bin_id='bin-a1'", [product])).rows[0]?.quantity || 0);
    await call("inventory/count/start", cashier, { ...part, transactionId: randomUUID() }, 403);
    await call("inventory/count", manager, { ...part, counted: 0, transactionId: randomUUID() }, 400);
    const draft = await start();
    assert.equal(draft.expected, 20);
    await confirm(draft.id, manager, 409);
    await submit(draft.id, 15);
    await confirm(draft.id, staff, 403);
    await confirm(draft.id, mumbai, 404);
    const shift = await call("shifts/open", owner, { openingCash: 0 });
    await call("invoices", owner, { transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ ...part, qty: 1 }], tenders: [{ type: "Cash", amount: 300000, confirmed: true }] });
    assert.equal(await onHand(), 19);
    await confirm(draft.id, manager, 409);
    assert.equal(await onHand(), 19);
    // A movement back to the original quantity must also invalidate an earlier observation.
    await call("inventory/adjust", owner, { ...part, quantity: 1, reason: "Back in bin" });
    assert.equal(await onHand(), 20);
    await confirm(draft.id, manager, 409);
    await call("inventory/count/discard", manager, { countId: draft.id });
    const fresh = await start();
    await submit(fresh.id, 0);
    const confirmId = randomUUID();
    const closed = await confirm(fresh.id, manager, 200, confirmId);
    assert.deepEqual([closed.expected, closed.counted, closed.delta, closed.status], [20, 0, -20, "confirmed"]);
    assert.equal((await confirm(fresh.id, manager, 200, confirmId)).id, fresh.id);
    assert.equal((await confirm(fresh.id, manager)).id, fresh.id);
    assert.equal(await onHand(), 0);
    const movements = await db.query("SELECT quantity FROM stock_ledger WHERE reference_id=$1", [fresh.id]);
    assert.deepEqual(movements.rows.map(row => Number(row.quantity)), [-20]);
    const audit = (await records(db, "demo", "audit", "pune")).filter(row => row.subject === fresh.id);
    assert.equal(audit.length, 1);
    assert.deepEqual([audit[0].details.expected, audit[0].details.counted, audit[0].details.quantity], [20, 0, -20]);
    const exact = await start();
    await submit(exact.id, 0);
    assert.equal((await confirm(exact.id)).delta, 0);
    assert.equal((await db.query("SELECT id FROM stock_ledger WHERE reference_id=$1", [exact.id])).rows.length, 0);
    const increment = await start();
    await submit(increment.id, 3);
    await confirm(increment.id);
    assert.equal(await onHand(), 3);
    const reserved = await start();
    await submit(reserved.id, 0);
    await call("holds", owner, { cart: { lines: [{ ...part, qty: 1 }] } });
    await confirm(reserved.id, manager, 409);
    assert.equal(await onHand(), 3);

    const serial = await call("products", owner, { name: "Counted serial", sku: "COUNT-SERIAL", brand: "Demo",
      category: "Parts", unit: "Each", retailPrice: 1000, serialTracked: true, taxRate: 0 });
    const serialBin = { productId: serial.id, binId: part.binId };
    const init = await start(staff, serialBin);
    await submit(init.id, 2, ["A", "A"], 400);
    await submit(init.id, 2, ["A", "B"]);
    await confirm(init.id);
    assert.equal(await onHand(serial.id), 2);
    const swap = await start(staff, serialBin), parallel = await start(staff, serialBin);
    await submit(swap.id, 2, ["A", "C"]);
    await submit(parallel.id, 2, ["A", "B"]);
    const changed = await confirm(swap.id);
    assert.deepEqual(changed.serialChanges, { added: ["C"], removed: ["B"] });
    assert.equal((await getRecord(db, "demo", "serial", serial.id + ":B"))?.status, "adjusted-out");
    assert.equal(await onHand(serial.id), 2);
    await confirm(parallel.id, manager, 409);
    const blocked = await start(staff, serialBin);
    await submit(blocked.id, 2, ["C", "D"]);
    await call("holds", owner, { cart: { lines: [{ ...serialBin, qty: 1, serials: ["A"] }] } });
    await confirm(blocked.id, manager, 409);
    assert.equal((await getRecord(db, "demo", "serial", serial.id + ":A"))?.status, "available");
    const visible = (await call("bootstrap", manager)).stockCounts;
    assert.ok(visible.some((row: any) => row.id === blocked.id));
    assert.ok(!visible.some((row: any) => row.id === fresh.id || row.id === draft.id));
    assert.equal((await call("bootstrap", cashier)).stockCounts, undefined);
  } finally {
    await app.close();
    await db.close();
  }
});
