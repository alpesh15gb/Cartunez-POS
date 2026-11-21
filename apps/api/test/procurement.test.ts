// WS-E: reorder alerts → draft purchase orders → receive with cost-hike checks → price update and online sync status.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { priceKeepingMargin, margin, netPrice } from "../src/cost-changes.js";

test("cost-change maths: margin before GST and the price that keeps it", () => {
  assert.equal(netPrice(11800, 1800, "inclusive"), 10000);
  assert.equal(netPrice(10000, 1800, "exclusive"), 10000);
  assert.equal(margin(10000, 6000), 4000);
  assert.equal(margin(0, 6000), null);
  // Cost 600 → 690 (+15%): price 1,000 becomes 1,150 to keep the same margin.
  assert.equal(priceKeepingMargin(100000, 60000, 69000), 115000);
});

test("Procurement: reorder alerts make draft POs per supplier; receiving flags cost hikes", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db, {});
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({ method: method as any, url: "/api/v1/" + path, payload: body, headers: token ? { authorization: "Bearer " + token } : {} });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const get = (path: string, token: string, status = 200) => call(path, undefined, token, status, "GET");
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const stock = await login("inventory@motorline.local");
    const cashier = await login("cashier@motorline.local");

    // Three parts fall below their reorder level: two suppliers, one part without a supplier.
    const other = await call("suppliers", { name: "Second Supplier" }, owner);
    await call("products", { id: "filter", reorderLevel: 30 }, owner);
    await call("products", { id: "battery", reorderLevel: 30, supplierId: other.id }, owner);
    await call("products", { id: "wiper", reorderLevel: 30, supplierId: "" }, owner);
    const alerts = (await get("bootstrap", owner)).reorderSuggestions;
    assert.deepEqual(alerts.map((a: any) => a.productId).sort(), ["battery", "filter", "wiper"]);

    await call("purchase-orders/from-suggestions", {}, cashier, 403);
    const drafts = await call("purchase-orders/from-suggestions", {}, stock);
    assert.equal(drafts.purchaseOrders.length, 2);
    assert.deepEqual(drafts.noSupplier.map((p: any) => p.productId), ["wiper"]);
    const filterPo = drafts.purchaseOrders.find((po: any) => po.supplierId === "supplier-1");
    const batteryPo = drafts.purchaseOrders.find((po: any) => po.supplierId === other.id);
    assert.equal(filterPo.status, "draft");
    assert.deepEqual(filterPo.lines.map((l: any) => [l.productId, l.quantity, l.cost]), [["filter", 36, 17100]]);
    // Drafts count as on order: nothing is suggested twice.
    const again = await call("purchase-orders/from-suggestions", {}, stock);
    assert.equal(again.purchaseOrders.length, 0);
    assert.equal((await get("bootstrap", owner)).reorderSuggestions.find((a: any) => a.productId === "filter").suggestedQuantity, 0);

    // Edit a draft, then place it.
    await call(`purchase-orders/${filterPo.id}/lines`, { lines: [{ productId: "filter", quantity: 10, cost: 17100 }] }, stock);
    const placed = await call(`purchase-orders/${filterPo.id}/place`, {}, stock);
    assert.equal(placed.status, "open");
    await call(`purchase-orders/${filterPo.id}/place`, {}, stock, 409);

    // The supplier charges 200 instead of 171 (+17%): the receipt line is flagged.
    const receipt = await call(`purchase-orders/${filterPo.id}/receive`, {
      transactionId: randomUUID(),
      lines: [{ productId: "filter", quantity: 10, binId: "bin-a1", cost: 20000 }],
    }, stock);
    const hike = receipt.lines[0].costHike;
    assert.equal(hike.oldCost, 17100);
    assert.equal(hike.newCost, 20000);
    assert.equal(hike.increase, 1696);
    assert.equal(hike.oldMargin, 4000);
    assert.equal(hike.newMargin, 2982);
    assert.equal(hike.suggestedPrice, 33400);
    assert.equal((await getRecord(db, "demo", "product", "filter"))!.lastPurchaseCost, 20000);

    // Billing the battery order at the same cost, then +3%: neither is flagged (threshold 5%).
    const same = await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: other.id, purchaseOrderId: batteryPo.id, billNumber: "B-1",
      lines: [{ productId: "battery", quantity: batteryPo.lines[0].quantity, cost: 329940, binId: "bin-a1" }],
    }, stock);
    assert.equal(same.lines[0].costHike, undefined);
    assert.equal((await getRecord(db, "demo", "purchaseOrder", batteryPo.id))!.status, "received");
    const small = await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: other.id, billNumber: "B-2",
      lines: [{ productId: "battery", quantity: 1, cost: 339840, binId: "bin-a1" }],
    }, stock);
    assert.equal(small.lines[0].costHike, undefined);
    // A bill +20% over the last purchase cost is flagged.
    const big = await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: other.id, billNumber: "B-3",
      lines: [{ productId: "battery", quantity: 1, cost: 407808, binId: "bin-a1" }],
    }, stock);
    assert.equal(big.lines[0].costHike.oldCost, 339840);
    assert.equal(big.costHikes, 1);

    // The cost-changes list, and the quick "update selling price".
    let list = await get("cost-changes", stock);
    assert.equal(list.threshold, 500);
    assert.deepEqual(list.changes.map((c: any) => c.productId).sort(), ["battery", "filter"]);
    const filterChange = list.changes.find((c: any) => c.productId === "filter");
    await call(`cost-changes/${filterChange.id}/apply`, {}, stock, 403);
    const applied = await call(`cost-changes/${filterChange.id}/apply`, { retailPrice: 33500 }, owner);
    assert.equal(applied.status, "priceUpdated");
    assert.equal((await getRecord(db, "demo", "product", "filter"))!.retailPrice, 33500);
    await call(`cost-changes/${list.changes.find((c: any) => c.productId === "battery").id}/dismiss`, {}, stock);
    list = await get("cost-changes", stock);
    assert.equal(list.changes.length, 0);
    assert.equal((await get("cost-changes?status=all", stock)).changes.length, 2);

    // A higher threshold stops flagging the same rise.
    await call("purchasing/settings", { costHikeThreshold: 2500 }, owner);
    const quiet = await call("purchase-bills", {
      transactionId: randomUUID(), supplierId: other.id, billNumber: "B-4",
      lines: [{ productId: "battery", quantity: 1, cost: 489370, binId: "bin-a1" }],
    }, stock);
    assert.equal(quiet.lines[0].costHike, undefined);

    // Online sync status for the received parts (Magento not connected here).
    const synced = await call("purchasing/sync-online", { productIds: ["filter", "battery"] }, stock);
    assert.deepEqual(synced.parts.map((p: any) => p.state), ["not-connected", "not-connected"]);
    assert.equal((await get("purchasing/sync-status?productIds=filter", stock)).parts[0].productId, "filter");

    // A received order cannot be cancelled; a draft can, and cancelled orders take no goods.
    await call(`purchase-orders/${filterPo.id}/cancel`, {}, stock, 409);
    await call("products", { id: "wiper", supplierId: "supplier-1" }, owner);
    const wiperPo = (await call("purchase-orders/from-suggestions", { lines: [{ productId: "wiper", quantity: 4 }] }, stock)).purchaseOrders[0];
    assert.equal(wiperPo.lines[0].quantity, 4);
    assert.equal((await call(`purchase-orders/${wiperPo.id}/cancel`, { reason: "Not needed" }, stock)).status, "cancelled");
    await call(`purchase-orders/${wiperPo.id}/receive`, { transactionId: randomUUID(), lines: [{ productId: "wiper", quantity: 1, binId: "bin-a1" }] }, stock, 400);
  } finally {
    await app.close();
    await db.close();
  }
});
