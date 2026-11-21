import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { itemTargets, pollMagentoOrders } from "../src/magento-orders.js";

test("financial refunds release outstanding demand and preserve physical deductions across upgrades", () => {
  const item = { qty_ordered: 5, qty_invoiced: 5, qty_refunded: 2, qty_shipped: 0 };
  const previous = { invoiced: 5, refunded: 0, sold: 5, deducted: 3 };
  assert.equal(itemTargets(item, previous).sold, 3);
  assert.equal(itemTargets(item, { ...previous, deducted: 5 }).sold, 5);
  const legacy = { invoiced: 5, refunded: 2, sold: 3, deducted: 3 };
  assert.equal(itemTargets({ ...item, qty_shipped: 5 }, legacy).sold, 3);
  assert.equal(itemTargets({ ...item, qty_shipped: 5 }).sold, 5);
});

/** Magento with an editable list of orders, as GET /V1/orders returns them. */
function fakeMagento() {
  const orders: any[] = [];
  let token = "test-token";
  const fetch = (async (url: string | URL, init: any = {}) => {
    const u = new URL(String(url));
    const reply = (status: number, data: unknown) =>
      new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
    if (init.headers?.Authorization !== `Bearer ${token}`) return reply(401, { message: "The consumer isn't authorized to access %resources.", parameters: { resources: "Magento_Sales::actions_view" } });
    if (u.pathname === "/rest/V1/store/storeConfigs") return reply(200, [{ base_currency_code: "INR" }]);
    if (u.pathname === "/rest/all/V1/orders") {
      const since = u.searchParams.get("searchCriteria[filter_groups][0][filters][0][value]")!;
      const items = orders.filter((o) => o.updated_at >= since).sort((a, b) => a.updated_at.localeCompare(b.updated_at));
      const page = Number(u.searchParams.get("searchCriteria[currentPage]"));
      const size = Number(u.searchParams.get("searchCriteria[pageSize]"));
      return reply(200, { items: items.slice((page - 1) * size, page * size), total_count: items.length });
    }
    if (u.pathname.startsWith("/rest/all/V1/products/")) return reply(200, { id: 1, sku: "x" });
    return reply(404, { message: "Not found" });
  }) as typeof globalThis.fetch;
  let clock = Date.now();
  const stamp = () => new Date(clock = Math.max(Date.now(), clock + 1000)).toISOString().slice(0, 19).replace("T", " ");
  const order = (n: number, items: [string, number][], extra: any = {}) => {
    const o = {
      entity_id: n,
      increment_id: `00000000${n}`,
      state: "new",
      status: "pending",
      created_at: stamp(),
      updated_at: stamp(),
      customer_firstname: "Asha",
      customer_lastname: "Rao",
      customer_email: "asha@example.com",
      grand_total: 1000,
      order_currency_code: "INR",
      extension_attributes: { shipping_assignments: [{ shipping: { address: { street: ["12 MG Road"], city: "Pune", postcode: "411001", telephone: "9800000000" } } }] },
      items: items.map(([sku, qty], i) => ({ item_id: n * 10 + i, sku, name: sku, qty_ordered: qty, qty_invoiced: 0, qty_canceled: 0, qty_refunded: 0, price_incl_tax: 100, product_type: "simple" })),
      ...extra,
    };
    orders.push(o);
    return o;
  };
  const update = (o: any, change: (item: any) => void, state?: string) => {
    o.items.forEach(change);
    if (state) o.state = state;
    o.updated_at = stamp();
  };
  return { fetch, order, update, setToken: (t: string) => (token = t) };
}

// WS-E: these orders were read before the POS invoiced online orders ("magento"
// mode): Magento invoices still take their stock. New orders: fulfilment.test.ts.
test("Magento orders reserve, sell on invoice, refund, wait for stock, cancel and order from supplier", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const magento = fakeMagento();
  const app = await createApp(db, { fetch: magento.fetch });
  try {
    const call = async (path: string, body: any, token?: string, status = 200) => {
      const response = await app.inject({ method: "POST", url: "/api/v1/" + path, payload: body, headers: token ? { authorization: "Bearer " + token } : {} });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    // Strict stock for these checks (selling beyond stock switched off).
    await call("settings", { features: { negativeStock: false } }, owner);
    const cashier = await login("cashier@motorline.local");
    const boot = async (token: string) =>
      (await app.inject({ method: "GET", url: "/api/v1/bootstrap", headers: { authorization: "Bearer " + token } })).json();
    const available = async (productId: string) =>
      (await boot(owner)).stock.filter((s: any) => s.productId === productId).reduce((n: number, s: any) => n + s.available, 0);
    const onHand = async (productId: string) =>
      Number((await db.query("SELECT COALESCE(SUM(quantity),0) q FROM stock WHERE organization_id='demo' AND branch_id='pune' AND product_id=$1", [productId])).rows[0].q);
    const poll = () => pollMagentoOrders(db, { fetch: magento.fetch, organizationId: "demo" });
    const online = (n: number) => getRecord(db, "demo", "onlineOrder", `mg-${n}`);
    // Older orders already being handled the old way when the POS started invoicing.
    const older = (n: number) =>
      putRecord(db, "demo", "onlineOrder", { id: `mg-${n}`, mode: "magento", lines: [], updatedAt: "2000-01-01T00:00:00Z" }, "pune");
    for (const n of [1, 2, 3]) await older(n);

    await call("integrations/magento", { baseUrl: "http://magento.test", token: "test-token", branchId: "pune", enabled: true }, owner);

    // 1. A new order holds 3 oil filters: the counter can no longer sell them.
    assert.equal(await available("filter"), 24);
    const o1 = magento.order(1, [["ML-FILTER-01", 3]]);
    assert.equal((await poll()).imported, 1);
    let rec = await online(1);
    assert.equal(rec!.posState, "reserved");
    assert.equal(rec!.number, "000000001");
    assert.equal(rec!.customer.name, "Asha Rao");
    assert.equal(rec!.shipTo, "12 MG Road, Pune, 411001");
    assert.equal(rec!.lines[0].reserved, 3);
    assert.equal(await available("filter"), 21);
    assert.equal(await onHand("filter"), 24);
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    const sale = (qty: number) => ({
      transactionId: randomUUID(),
      shiftId: shift.id,
      lines: [{ productId: "filter", qty, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 10000000, confirmed: true }],
    });
    await call("invoices", sale(19), cashier, 409); // bin A1 has 19, three are held for the website

    // Reading the same order again changes nothing.
    await poll();
    assert.equal(await onHand("filter"), 24);

    // 2. Magento invoices it: the units leave the bins.
    magento.update(o1, (i) => (i.qty_invoiced = 3), "processing");
    await poll();
    rec = await online(1);
    assert.equal(rec!.posState, "sold");
    assert.equal(rec!.lines[0].deducted, 3);
    assert.equal(await onHand("filter"), 21);
    assert.equal(await available("filter"), 21);
    const ledger = (await db.query("SELECT reason, quantity FROM stock_ledger WHERE organization_id='demo' AND reference_id='mg-1'")).rows;
    assert.deepEqual(ledger.map((r: any) => [r.reason, Number(r.quantity)]), [["Online order #000000001", -3]]);
    await poll();
    assert.equal(await onHand("filter"), 21);

    // 3. A money-only refund cannot create sellable stock, even on a replay.
    magento.update(o1, (i) => (i.qty_refunded = 1), "processing");
    await poll();
    rec = await online(1);
    assert.equal(rec!.lines[0].deducted, 3);
    assert.equal(rec!.lines[0].refunded, 1);
    await poll();
    assert.equal(await onHand("filter"), 21);

    // 4. More batteries sold online than the shop has: it waits for stock.
    assert.equal(await onHand("battery"), 21);
    const o2 = magento.order(2, [["ML-BATTERY-01", 25]]);
    magento.update(o2, (i) => (i.qty_invoiced = 25), "processing");
    await poll();
    rec = await online(2);
    assert.equal(rec!.posState, "awaiting");
    assert.equal(rec!.lines[0].deducted, 21);
    assert.equal(rec!.lines[0].awaiting, 4);
    assert.equal(rec!.lines[0].shortage, 4);
    assert.equal(await onHand("battery"), 0);

    // Order the missing 4 from the supplier.
    const { purchaseOrderIds } = await call("online-orders/mg-2/purchase-order", {}, owner);
    const po = await getRecord(db, "demo", "purchaseOrder", purchaseOrderIds[0]);
    assert.equal(po!.supplierId, "supplier-1");
    assert.deepEqual(po!.lines.map((l: any) => [l.productId, l.quantity]), [["battery", 4]]);
    assert.equal(po!.note, "For online order #000000002");
    await call("online-orders/mg-2/purchase-order", {}, owner, 409);

    // Stock arrives: it is held for the order, and Fulfil takes it.
    await call("inventory/adjust", { productId: "battery", binId: "bin-a1", quantity: 4, reason: "Received", transactionId: randomUUID() }, owner);
    assert.equal(await available("battery"), 0);
    rec = await call("online-orders/mg-2/fulfil", {}, owner);
    assert.equal(rec.posState, "sold");
    assert.equal(rec.lines[0].awaiting, 0);
    assert.equal(await onHand("battery"), 0);

    // 5. A cancelled order releases what it held.
    const o3 = magento.order(3, [["ML-WIPER-01", 2]]);
    await poll();
    assert.equal((await online(3))!.posState, "reserved");
    const wiperBefore = await available("wiper");
    magento.update(o3, (i) => (i.qty_canceled = 2), "canceled");
    await poll();
    assert.equal((await online(3))!.posState, "cancelled");
    assert.equal(await available("wiper"), wiperBefore + 2);

    // 6. A SKU the POS does not know is shown, not guessed.
    magento.order(4, [["SOMETHING-ELSE", 1]]);
    await poll();
    rec = await online(4);
    assert.equal(rec!.lines[0].productId, null);
    assert.equal(rec!.posState, "unmatched");

    // Managers see online orders; cashiers do not and cannot check Magento.
    assert.equal((await boot(owner)).onlineOrders.length, 4);
    assert.deepEqual((await boot(cashier)).onlineOrders, []);
    await call("integrations/magento/orders/poll", {}, cashier, 403);
    assert.equal((await call("integrations/magento/orders/poll", {}, owner)).imported >= 0, true);

    const hold = await call("holds", {
      cart: { lines: [{ productId: "filter", binId: "bin-a1", qty: 16 }] },
    }, owner);
    magento.order(5, [["ML-FILTER-01", 4]]);
    await poll();
    const filterStock = (await boot(owner)).stock.filter((row: any) => row.productId === "filter");
    assert.ok(filterStock.every((row: any) => row.available >= 0));
    assert.equal(filterStock.reduce((n: number, row: any) => n + row.available, 0), 1);
    assert.ok(hold.id);
    for (let n = 6; n < 68; n++) magento.order(n, [["UNMATCHED", 1]]);
    await poll();
    assert.equal((await records(db, "demo", "onlineOrder")).length, 67);

    const serialPart = await call("products", { sku: "TRACKED-ONLINE", name: "Serialized test item", brand: "Fixture", category: "Parts", unit: "Each", serialTracked: true, retailPrice: 10000 }, owner);
    await call("online-listings", { productIds: [serialPart.id], changes: { published: true } }, owner, 400);
    await call("inventory/adjust", { productId: serialPart.id, binId: "bin-a1", quantity: 1, serials: ["PICK-1"], reason: "Test stock" }, owner);
    await older(68);
    const external = magento.order(68, [["TRACKED-ONLINE", 1]]);
    magento.update(external, i => (i.qty_invoiced = 1), "processing");
    await poll();
    const tracked = (await online(68))!.lines[0];
    assert.equal(tracked.serialPickRequired, true);
    assert.equal(tracked.awaiting, 1);
    assert.equal(tracked.deducted, 0);
    assert.equal(await onHand(serialPart.id), 1);

    // A revoked token is reported on "Check now" and kept for the screen.
    magento.setToken("rotated");
    const bad = await call("integrations/magento/orders/poll", {}, owner, 502);
    assert.match(bad.error, /isn't authorized/);
    assert.match((await boot(owner)).onlineOrdersCheck.error, /isn't authorized/);
    assert.equal((await records(db, "demo", "onlineOrder")).length, 68);
  } finally {
    await app.close();
    await db.close();
  }
});
