import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createApp } from "../src/app.js";
import { connectDatabase, getRecord, migrate, putRecord } from "../src/db.js";
import { seed } from "../src/seed.js";
import { importMagentoOrder } from "../src/magento-orders.js";

test("supplier withdrawals respect pooled stock, reserved serials and the original receiving bin", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    const token = (await app.inject({ method: "POST", url: "/api/v1/auth/login",
      payload: { email: "owner@motorline.local", password: "MotorlineDemo123!" } })).json().token;
    const headers = { authorization: "Bearer " + token };
    const post = async (path: string, body: any, status = 200) => {
      const reply = await app.inject({ method: "POST", url: "/api/v1/" + path, payload: body, headers });
      assert.equal(reply.statusCode, status, path + " " + reply.body);
      return reply.json();
    };
    const boot = async () => (await app.inject({ method: "GET", url: "/api/v1/bootstrap", headers })).json();
    const part = (sku: string, serialTracked = false) => post("products", { name: sku, sku, supplierId: "supplier-1",
      retailPrice: 1000, cost: 250, taxRate: 0, serialTracked });
    const line = (productId: string, quantity = 1, serials: string[] = []) => ({ productId, quantity, binId: "bin-a1", cost: 250, serials });
    const purchase = (...lines: any[]) => post("purchase-bills", { supplierId: "supplier-1", lines, billNumber: randomUUID() });
    const cancel = (bill: any, status = 200) => post("purchase-bills/" + bill.id + "/void", { reason: "Correction" }, status);
    const ret = (bill: any, lines: any[], status = 200) => post("purchase-returns", { billId: bill.id, supplierId: "supplier-1",
      transactionId: randomUUID(), reason: "Return to supplier", lines }, status);
    const hold = (p: any, serials: string[] = []) => post("holds", { cart: { lines: [{ productId: p.id, binId: "bin-a1", qty: 1, serials }] } });
    const release = async (id: string) => {
      const res = await app.inject({ method: "DELETE", url: "/api/v1/holds/" + id, headers });
      assert.equal(res.statusCode, 200, res.body);
    };
    const stock = async (p: any, binId = "bin-a1") => {
      const row = (await boot()).stock.find((r: any) => r.productId === p.id && r.binId === binId);
      return [row.quantity, row.reserved, row.available];
    };
    const tracked = await part("TrackedTest", true);
    await purchase(line(tracked.id, 1, ["S0"]));
    const billed = await purchase(line(tracked.id, 1, ["S1"]));
    const move = (fromBinId: string, toBinId: string) => post("inventory/move", {
      productId: tracked.id, quantity: 1, fromBinId, toBinId, serials: ["S1"], reason: "Move shelf",
    });
    await move("bin-a1", "bin-a2");
    await cancel(billed, 409);
    assert.deepEqual(await stock(tracked), [1, 0, 1]);
    assert.deepEqual(await stock(tracked, "bin-a2"), [1, 0, 1]);
    assert.equal((await getRecord(db, "demo", "serial", tracked.id + ":S1"))?.binId, "bin-a2");
    await move("bin-a2", "bin-a1");
    const parked = await hold(tracked, ["S1"]);
    assert.deepEqual(await stock(tracked), [2, 1, 1]);
    assert.match((await cancel(billed, 409)).error, /reserved/);
    assert.match((await ret(billed, [line(tracked.id, 1, ["S1"])], 409)).error, /reserved/);
    await ret(billed, [line(tracked.id, 1, ["S0"])], 409); // different bill's serial
    await release(parked.id);
    const job = await post("jobs", { customerId: "customer-1", lines: [{ productId: tracked.id, qty: 1, binId: "bin-a1", serials: ["S1"] }] });
    assert.match((await cancel(billed, 409)).error, /reserved/);
    assert.match((await ret(billed, [line(tracked.id, 1, ["S1"])], 409)).error, /reserved/);
    await post("jobs/" + job.id + "/status", { status: "cancelled" });
    // Available in another branch, or unaccounted for, still cannot cancel this bill.
    const valid = (await getRecord(db, "demo", "serial", tracked.id + ":S1"))!;
    await putRecord(db, "demo", "serial", { ...valid, branchId: "mumbai" }, "mumbai");
    await cancel(billed, 409);
    await db.query("DELETE FROM records WHERE organization_id='demo' AND kind='serial' AND id=$1", [valid.id]);
    await cancel(billed, 409);
    await putRecord(db, "demo", "serial", valid, "pune");
    const expired = await hold(tracked, ["S1"]);
    await putRecord(db, "demo", "hold", { ...expired, expiresAt: "2020-01-01T00:00:00Z" }, "pune");
    await cancel(billed); // expired reservations no longer block the serial
    await release(expired.id);
    assert.deepEqual(await stock(tracked), [1, 0, 1]);
    assert.ok(await getRecord(db, "demo", "serial", tracked.id + ":S0"));
    assert.equal(await getRecord(db, "demo", "serial", valid.id), undefined);

    const plain = await part("ReservedTest");
    const original = await purchase(line(plain.id), line(plain.id));
    const held = await hold(plain);
    // Filtering each line independently would let both lines take the same free unit.
    await ret(original, [line(plain.id), line(plain.id)], 409);
    await cancel(original, 409);
    assert.deepEqual(await stock(plain), [2, 1, 1]);
    await release(held.id);
    const order = await importMagentoOrder(db, "demo", "pune", { entity_id: 334, increment_id: "T334",
      grand_total: 20, items: [{ item_id: 1, sku: plain.sku, qty_ordered: 2, price: 10 }] });
    await ret(original, [line(plain.id)], 409);
    await cancel(original, 409);
    assert.deepEqual(await stock(plain), [2, 2, 0]);
    await importMagentoOrder(db, "demo", "pune", { entity_id: order.magentoId, increment_id: "T334", grand_total: 0,
      items: [{ item_id: 1, sku: plain.sku, qty_ordered: 2, qty_canceled: 2, price: 10 }] });
    await ret(original, [line(plain.id, 2)]);
    assert.deepEqual(await stock(plain), [0, 0, 0]);

    const web = await part("SharedShelf");
    await purchase(line(web.id, 4));
    const kit = await post("products", { sku: "KitShelfTest", name: "Kit", retailPrice: 100,
      components: [{ productId: web.id, qty: 1 }] });
    const kitHold = await post("holds", { cart: { lines: [{ productId: kit.id, qty: 1 }] } });
    const mg = (id: number, quantities: number[]) => ({ entity_id: id, increment_id: String(id), grand_total: 20,
      items: quantities.map((qty, i) => ({ item_id: i + 1, sku: web.sku, name: web.name, qty_ordered: qty, price: 10 })) });
    const first = mg(731, [2,2]);
    const imported = await importMagentoOrder(db, "demo", "pune", first);
    assert.deepEqual(imported.lines.map((l: any) => l.shortage), [0, 1]);
    const later = await importMagentoOrder(db, "demo", "pune", mg(732, [1]));
    assert.equal(later.lines[0].shortage, 1);
    assert.deepEqual((await importMagentoOrder(db, "demo", "pune", first)).lines.map((l: any) => l.shortage), [0, 1]);
    // Older records have stale zero shortages. The PO route must read inventory again.
    await putRecord(db, "demo", "onlineOrder", { ...imported, lines: imported.lines.map((l: any) => ({ ...l, shortage: 0 })) }, "pune");
    const purchaseOrders = await post("online-orders/mg-731/purchase-order", {});
    const po = await getRecord(db, "demo", "purchaseOrder", purchaseOrders.purchaseOrderIds[0]);
    assert.deepEqual(po?.lines.map((l: any) => [l.productId, l.quantity]), [[web.id, 1]]);
    await post("online-orders/mg-731/purchase-order", {}, 409);
    await release(kitHold.id);
    const refreshed = await post("online-orders/mg-731/fulfil", {});
    assert.deepEqual(refreshed.lines.map((l: any) => l.shortage), [0, 0]);
  } finally {
    await app.close();
    await db.close();
  }
});
