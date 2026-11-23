// Online only items: parts listed only on the website and ordered from the
// supplier when a customer buys them. They are never shop stock: refused at the
// counter, published to Magento as always sellable (stock not managed), invoiced
// from Online orders as non-stock lines, and bought in without adding stock.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { pollMagentoOrders } from "../src/magento-orders.js";
import { runMagentoSync, magentoProduct } from "../src/magento.js";
import { buildProduct, previewCatalog, CatalogCodes } from "../src/catalog.js";
import { fakeMagento } from "./fake-magento-shop.js";

test("online only: product field, CSV column and Magento stock fields", () => {
  const plain = buildProduct({ name: "Mat", retailPrice: 100 });
  assert.equal(plain.onlineOnly, false);
  const online = buildProduct({ name: "Alloy", retailPrice: 100, onlineOnly: true, serialTracked: true });
  assert.equal(online.onlineOnly, true);
  assert.equal(online.serialTracked, false);
  // A service (or kit) can never be online only.
  assert.equal(buildProduct({ name: "Labour", retailPrice: 100, type: "service", onlineOnly: true }).onlineOnly, false);
  const csv = "name,retailPrice,onlineOnly\nRoof box,1000,yes\nSeat cover,500,\n";
  const preview = previewCatalog(csv, new CatalogCodes([]), false);
  assert.equal(preview.valid, true);
  assert.deepEqual(preview.products.map((p) => p.onlineOnly), [true, false]);
  assert.equal(previewCatalog("name,retailPrice,onlineOnly\nX,1,maybe\n", new CatalogCodes([]), false).valid, false);
  // The import's description column becomes the website text when the listing has none.
  const described = previewCatalog('name,retailPrice,onlineOnly,description\nAmp,5000,yes,"Four-channel amp, 50 W x 4."\n', new CatalogCodes([]), false);
  assert.equal(described.valid, true);
  assert.equal(described.products[0].description, "Four-channel amp, 50 W x 4.");
  const site = magentoProduct(described.products[0], { published: true }, { mrp: 500000, selling: 500000 }, 0, {});
  assert.equal(site.product.custom_attributes.find((a: any) => a.attribute_code === "description")?.value, "Four-channel amp, 50 W x 4.");
  const own = magentoProduct(described.products[0], { published: true, description: "Listing text" }, { mrp: 500000, selling: 500000 }, 0, {});
  assert.equal(own.product.custom_attributes.find((a: any) => a.attribute_code === "description")?.value, "Listing text");
  const multi = previewCatalog('name,retailPrice,description\r\nMat,1,"Line one\r\nLine two"\r\n', new CatalogCodes([]), false);
  assert.equal(multi.products[0].description, "Line one\nLine two");
  const clear = magentoProduct({ ...online, description: "" }, { description: "" }, { mrp: 1, selling: 1 }, 0, {});
  assert.equal(clear.product.custom_attributes.find((a: any) => a.attribute_code === "description")?.value, "");
  // Magento: always sellable, stock not managed, never the POS quantity.
  const body = magentoProduct(online, { published: true }, { mrp: 10000, selling: 9000 }, 7, {});
  const stock = body.product.extension_attributes.stock_item as any;
  assert.equal(stock.manage_stock, false);
  assert.equal(stock.use_config_manage_stock, false);
  assert.equal(stock.is_in_stock, true);
  assert.equal("qty" in stock, false);
  const shop = magentoProduct(plain, { published: true }, { mrp: 10000, selling: 9000 }, 7, {}).product.extension_attributes.stock_item as any;
  assert.equal(shop.qty, 7);
  assert.equal(shop.manage_stock, true);
});

test("online only: outside POS stock, counter refused, mixed online order, purchase order and receipt", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const magento = fakeMagento();
  const puts: { path: string; body: any }[] = [];
  const fetch = (async (url: string | URL, init: any = {}) => {
    const u = new URL(String(url));
    if ((init.method || "GET") === "PUT" && u.pathname.startsWith("/rest/all/V1/products/"))
      puts.push({ path: decodeURIComponent(u.pathname), body: JSON.parse(init.body) });
    // Categories (shop category and brand page) are found by name.
    if (u.pathname === "/rest/all/V1/categories/list")
      return new Response(JSON.stringify({ items: [{ id: 5 }] }), { status: 200, headers: { "Content-Type": "application/json" } });
    return magento.fetch(url, init);
  }) as typeof globalThis.fetch;
  const app = await createApp(db, { fetch });
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({ method: method as any, url: "/api/v1/" + path, payload: body, headers: token ? { authorization: "Bearer " + token } : {} });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const boot = () => call("bootstrap", undefined, owner, 200, "GET");
    const onHand = async (productId: string) =>
      Number((await db.query("SELECT COALESCE(SUM(quantity),0) q FROM stock WHERE organization_id='demo' AND branch_id='pune' AND product_id=$1", [productId])).rows[0].q);
    const movements = async (productId: string) =>
      Number((await db.query("SELECT count(*) n FROM stock_ledger WHERE organization_id='demo' AND product_id=$1", [productId])).rows[0].n);
    const poll = () => pollMagentoOrders(db, { fetch, organizationId: "demo" });
    await call("integrations/magento", { baseUrl: "http://magento.test", token: "test-token", branchId: "pune", enabled: true, prepaidMethods: "razorpay" }, owner);

    // An online-only part (usual supplier set), with a reorder level that would otherwise alert.
    const alloy = await call("products", {
      name: "Alloy Wheel Set", sku: "CZ-ALLOY-01", brand: "Cartunez", category: "Wheels", hsnSac: "8708",
      cost: 6000, retailPrice: 10000, wholesalePrice: 9500, taxRate: 1800, reorderLevel: 5,
      supplierId: "supplier-1", onlineOnly: true,
    }, owner);
    assert.equal(alloy.onlineOnly, true);
    // A stocked part cannot become online only while it has shop stock.
    const filter = await getRecord(db, "demo", "product", "filter");
    await call("products", { ...filter, onlineOnly: true }, owner, 409);

    // Counter: sale, hold and job card refused with a clear message.
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    const refused = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: alloy.id, qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 11800, confirmed: true }],
    }, cashier, 409);
    assert.match(refused.error, /Online only — sold on the website/);
    const held = await call("holds", { cart: { transactionId: "t-h", lines: [{ productId: alloy.id, qty: 1, binId: "bin-a1", serials: [] }] } }, cashier, 409);
    assert.match(held.error, /Online only/);
    // No stock: adjust, count and movements refused.
    await call("inventory/adjust", { productId: alloy.id, binId: "bin-a1", quantity: 3, reason: "Found", transactionId: randomUUID() }, owner, 400);
    await call("inventory/count/start", { productId: alloy.id, binId: "bin-a1", transactionId: randomUUID() }, owner, 400);

    // A kit cannot park an online-only item under a service line.
    await call("products", { name: "Bad kit", retailPrice: 1200, components: [{ productId: alloy.id, qty: 1 }] }, owner, 409);
    const component = await call("products", { name: "Shop only component", retailPrice: 100, taxRate: 0 }, owner);
    const kit = await call("products", { name: "Existing kit", retailPrice: 100, components: [{ productId: component.id, qty: 1 }] }, owner);
    await call("products", { id: component.id, onlineOnly: true }, owner, 409);
    // A kit already stored by the old release cannot be parked or checked out.
    await putRecord(db, "demo", "product", { ...kit, components: [{ productId: alloy.id, qty: 1 }] });
    const kitLines = [{ productId: kit.id, qty: 1 }];
    await call("holds", { cart: { lines: kitLines } }, owner, 409);
    await call("invoices", { transactionId: randomUUID(), shiftId: shift.id, lines: kitLines,
      tenders: [{ type: "Cash", amount: 10000, confirmed: true }] }, cashier, 409);

    const legacy = await call("products", { name: "Previously stocked item", retailPrice: 10000, taxRate: 0, hsnSac: "8708" }, owner);
    await call("inventory/adjust", { productId: legacy.id, binId: "bin-a1", quantity: 1, reason: "Stock opening" }, owner);
    const oldSale = await call("invoices", { transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: legacy.id, qty: 1, binId: "bin-a1" }], tenders: [{ type: "Cash", amount: 10000, confirmed: true }] }, cashier);
    assert.equal(await onHand(legacy.id), 0);
    await call("products", { id: legacy.id, onlineOnly: true }, owner, 409);
    await putRecord(db, "demo", "product", { ...legacy, onlineOnly: true }); // existing clients already converted it
    await call("shifts/open", { openingCash: 0 }, owner);
    const movementCount = await movements(legacy.id);
    const refund = await call("invoices/" + oldSale.id + "/returns", { transactionId: randomUUID(), condition: "sellable",
      reason: "Customer returned item", lines: [{ lineId: oldSale.lines[0].id, quantity: 1 }] }, owner);
    assert.equal(refund.refundTotal, 10000);
    assert.equal(refund.lines[0].stockDisposition, "outside-shop-stock");
    assert.equal(refund.lines[0].binId, null);
    assert.equal(await movements(legacy.id), movementCount);

    // Reorder alerts and valuation leave it out.
    assert.equal((await boot()).reorderSuggestions.some((r: any) => r.productId === alloy.id), false);
    assert.equal((await call("reports/low-stock", undefined, owner, 200, "GET")).rows.some((r: any) => r.productId === alloy.id), false);
    assert.equal((await call("reports/valuation", undefined, owner, 200, "GET")).rows.some((r: any) => r.productId === alloy.id), false);

    // Published: Magento always sells it, stock not managed, no POS quantity.
    await call("online-listings", { productIds: [alloy.id, "filter"], changes: { published: true } }, owner);
    await runMagentoSync(db, { fetch });
    const put = puts.find((p) => p.path.endsWith("/CZ-ALLOY-01"))!;
    assert.ok(put, "the online-only part is sent to Magento");
    assert.equal(put.body.product.status, 1);
    assert.equal(put.body.product.price, 118); // MRP with GST, as for shop parts
    assert.deepEqual(put.body.product.extension_attributes.stock_item, {
      is_in_stock: true, manage_stock: false, use_config_manage_stock: false, use_config_backorders: false, backorders: 1,
    });
    const shopPut = puts.find((p) => p.path.endsWith("/ML-FILTER-01"))!;
    assert.equal(shopPut.body.product.extension_attributes.stock_item.qty, 24);

    // A mixed website order: only the shop item reserves stock.
    magento.order(1, [["ML-FILTER-01", 2], ["CZ-ALLOY-01", 1]]);
    await poll();
    let order = await getRecord(db, "demo", "onlineOrder", "mg-1");
    const [filterLine, alloyLine] = order!.lines;
    assert.equal(filterLine.reserved, 2);
    assert.equal(alloyLine.onlineOnly, true);
    assert.equal(alloyLine.reserved, 0);
    assert.equal(alloyLine.awaiting, 0);
    assert.equal(alloyLine.shortage, 0);
    assert.equal(order!.posState, "reserved");
    const available = (await boot()).stock.filter((s: any) => s.productId === "filter").reduce((n: number, s: any) => n + s.available, 0);
    assert.equal(available, 22);

    // Pick & pack: "Order from supplier", nothing to pick for it.
    const picks = await call("online-orders/pick-list?ids=mg-1", undefined, owner, 200, "GET");
    const alloyRow = picks.orders[0].lines.find((l: any) => l.productId === alloy.id);
    assert.equal(alloyRow.orderFromSupplier, true);
    assert.deepEqual(alloyRow.bins, []);
    assert.equal(picks.items.some((i: any) => i.productId === alloy.id), false);

    // Create purchase order: a draft to the usual supplier, linked to the order.
    const { purchaseOrderIds, needsSupplier } = await call("online-orders/mg-1/purchase-order", {}, owner);
    assert.equal(purchaseOrderIds.length, 1);
    assert.deepEqual(needsSupplier, []);
    const po = await getRecord(db, "demo", "purchaseOrder", purchaseOrderIds[0]);
    assert.equal(po!.supplierId, "supplier-1");
    assert.equal(po!.status, "draft");
    assert.equal(po!.onlineOrderId, "mg-1");
    assert.deepEqual(po!.lines.map((l: any) => [l.productId, l.quantity, !!l.onlineOnly]), [[alloy.id, 1, true]]);
    await call("online-orders/mg-1/purchase-order", {}, owner, 409); // already ordered

    // A part with no usual supplier is listed so the user can choose one.
    const roof = await call("products", { name: "Roof Box", sku: "CZ-ROOF-01", hsnSac: "8708", cost: 3000, retailPrice: 5000, onlineOnly: true }, owner);
    magento.order(2, [["CZ-ROOF-01", 2]]);
    await poll();
    const asked = await call("online-orders/mg-2/purchase-order", {}, owner);
    assert.deepEqual(asked.purchaseOrderIds, []);
    assert.deepEqual(asked.needsSupplier.map((n: any) => [n.productId, n.quantity]), [[roof.id, 2]]);
    const chosen = await call("online-orders/mg-2/purchase-order", { suppliers: { [roof.id]: "supplier-1" } }, owner);
    assert.equal(chosen.purchaseOrderIds.length, 1);

    // Invoice & pack: both lines on the invoice; only the shop item moves stock.
    const packed = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2, binId: "bin-a1" }] }, owner);
    const invoice = packed.invoice;
    assert.equal(invoice.lines.length, 2);
    const invAlloy = invoice.lines.find((l: any) => l.productId === alloy.id);
    assert.equal(invAlloy.onlineOnly, true);
    assert.equal(invAlloy.binId, "");
    assert.equal(invAlloy.qty, 1);
    assert.equal(invAlloy.taxRate, 1800);
    assert.equal(invAlloy.unitPrice, 8475); // Rs 100 paid incl. 18% GST
    assert.ok(Math.abs(invoice.total - 30000) <= 3);
    assert.equal(packed.order.posState, "sold");
    assert.equal(await onHand("filter"), 22);
    assert.equal(await onHand(alloy.id), 0);
    assert.equal(await movements(alloy.id), 0);

    // Procurement remains possible after invoicing. Two of five units, across
    // two order lines for one SKU, were both received on a linked PO and shipped.
    const partial = { ...order!, id: "mg-partial", number: "partial-sourcing",
      purchaseOrderIds: ["po-prior"], fulfilment: { invoiceId: invoice.id }, lines: [
        { ...alloyLine, itemId: 21, ordered: 2, shipped: 2, posInvoiced: 2 },
        { ...alloyLine, itemId: 22, ordered: 3, shipped: 0, posInvoiced: 3 },
      ] };
    await putRecord(db, "demo", "onlineOrder", partial, "pune");
    await putRecord(db, "demo", "purchaseOrder", { id: "po-prior", status: "received",
      supplierId: "supplier-1", lines: [{ productId: alloy.id, quantity: 2, received: 2 }] }, "pune");
    const needed = async () => (await boot()).onlineOrders.find((o: any) => o.id === partial.id).supplierPurchaseNeeded;
    assert.equal(await needed(), true);
    const sourced = await call("online-orders/mg-partial/purchase-order", {}, owner);
    const tail = await getRecord(db, "demo", "purchaseOrder", sourced.purchaseOrderIds[0]);
    assert.deepEqual(tail!.lines.map((l: any) => l.quantity), [3]);
    assert.equal(await needed(), false);
    await call("online-orders/mg-partial/purchase-order", {}, owner, 409);
    await call("purchase-orders/" + tail!.id + "/cancel", {reason:"Supplier declined"}, owner);
    assert.equal(await needed(), true);

    // The supplier delivers: the receipt is recorded, but no shop stock.
    await call(`purchase-orders/${po!.id}/place`, {}, owner);
    const receipt = await call(`purchase-orders/${po!.id}/receive`, { transactionId: randomUUID(), lines: [{ productId: alloy.id, quantity: 1 }] }, owner);
    assert.equal(receipt.lines[0].binId, null);
    assert.equal(receipt.lines[0].onlineOnly, true);
    assert.equal((await getRecord(db, "demo", "purchaseOrder", po!.id))!.status, "received");
    assert.equal(await onHand(alloy.id), 0);

    // Its bill: owed to the supplier as usual, still no stock; cancelling it works.
    const before = (await boot()).partyBalances.suppliers["supplier-1"] || 0;
    const bill = await call("purchase-bills", { supplierId: "supplier-1", billNumber: "OO-1", lines: [{ productId: alloy.id, quantity: 1, cost: 6000 }] }, owner);
    assert.equal(bill.lines[0].binId, null);
    assert.equal(bill.total, 6000);
    assert.equal((await boot()).partyBalances.suppliers["supplier-1"], before + 6000);
    assert.equal(await onHand(alloy.id), 0);
    const unlinked = { supplierId: "supplier-1", reason: "Returned to supplier", lines: [{ productId: alloy.id, quantity: 1 }] };
    await call("purchase-returns", unlinked, owner, 409);
    const priced = await call("purchase-bills", { supplierId: "supplier-1", billNumber: "OO-2", discount: 3000,
      lines: [{ productId: alloy.id, quantity: 1, cost: 12000 }, { productId: alloy.id, quantity: 2, cost: 1500 }] }, owner);
    const firstCredit = await call("purchase-returns", { ...unlinked, billId: priced.id }, owner);
    assert.equal(firstCredit.total, 9600);
    const restCredit = await call("purchase-returns", { ...unlinked, billId: priced.id,
      lines: [{ productId: alloy.id, quantity: 2, cost: 12000 }] }, owner);
    assert.equal(restCredit.total, 2400);
    assert.equal(firstCredit.total + restCredit.total, priced.total);
    assert.equal(restCredit.lines[0].binId, null);
    await call("purchase-returns", { ...unlinked, billId: priced.id }, owner, 400);
    await call(`purchase-bills/${bill.id}/void`, { reason: "Entered twice" }, owner);
    assert.equal(await movements(alloy.id), 0);
    assert.equal((await boot()).reorderSuggestions.some((r: any) => r.productId === alloy.id), false);
  } finally {
    await app.close();
    await db.close();
  }
});
