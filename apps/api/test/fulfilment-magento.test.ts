// WS-E: online orders against a Magento 2.4.8 store with MSI: shipping that is
// never sent twice, the website quantity while an invoiced order waits to ship,
// Magento invoices once the money is in, bank transfer / UPI paid later,
// cancellations after the POS invoice, shipping charges and exact totals, COD
// after credit notes and voids, and the MSI source.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { pollMagentoOrders } from "../src/magento-orders.js";
import { runMagentoInvoices, runMagentoShipments } from "../src/fulfilment.js";
import { onlineQuantity } from "../src/magento.js";
import { fakeMagento } from "./fake-magento-shop.js";

async function setup(settings: any = {}) {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const magento = fakeMagento();
  const app = await createApp(db, { fetch: magento.fetch });
  const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
    const response = await app.inject({ method: method as any, url: "/api/v1/" + path, payload: body, headers: token ? { authorization: "Bearer " + token } : {} });
    assert.equal(response.statusCode, status, `${path}: ${response.body}`);
    return response.json();
  };
  const owner = (await call("auth/login", { email: "owner@motorline.local", password: "MotorlineDemo123!" })).token;
  await call("integrations/magento", { baseUrl: "http://magento.test", token: "test-token", branchId: "pune", enabled: true, prepaidMethods: "razorpay", ...settings }, owner);
  const poll = () => pollMagentoOrders(db, { fetch: magento.fetch, organizationId: "demo" });
  const online = async (n: number) => (await getRecord(db, "demo", "onlineOrder", `mg-${n}`))!;
  const ship = () => runMagentoShipments(db, { fetch: magento.fetch });
  const onHand = async (productId: string) =>
    Number((await db.query("SELECT COALESCE(SUM(quantity),0) q FROM stock WHERE organization_id='demo' AND branch_id='pune' AND product_id=$1", [productId])).rows[0].q);
  const close = async () => {
    await app.close();
    await db.close();
  };
  return { db, magento, call, owner, poll, online, ship, onHand, close };
}

test("Shipping is idempotent: shipped in the admin, lost replies, two workers at once, MSI source", async () => {
  const t = await setup({ sourceCode: "pune_shop" });
  const { magento, call, owner } = t;
  try {
    // 1. Shipped in the Magento admin before the POS sends it: no second shipment, our tracking is added.
    const o1 = magento.order(1, [["ML-FILTER-01", 2]]);
    await t.poll();
    await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2 }] }, owner);
    magento.update(o1, (i) => (i.qty_shipped = 2));
    magento.shipments.push({ orderId: 1, entity_id: 800, body: { items: [] }, tracks: [] });
    await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "DLV1" }, owner);
    assert.deepEqual(await t.ship(), { sent: 1, failed: 0 });
    let order = await t.online(1);
    assert.equal(order.fulfilment.shipment.state, "sent");
    assert.equal(order.fulfilment.shipment.alreadyShipped, true);
    assert.equal(magento.calls.filter((c) => c === "POST /rest/V1/order/1/ship").length, 0);
    assert.deepEqual(magento.tracks, [{ order_id: 1, parent_id: 800, track_number: "DLV1", title: "Delhivery", carrier_code: "custom" }]);

    // 2. Magento makes the shipment but the reply is lost: the order is read again and marked sent.
    magento.order(2, [["ML-FILTER-01", 1]]);
    await t.poll();
    await call("online-orders/mg-2/invoice", { picks: [{ itemId: 20, qty: 1 }] }, owner);
    await call("online-orders/mg-2/ship", { courier: "Blue Dart", tracking: "BD2" }, owner);
    magento.loseShipReplies(1);
    assert.deepEqual(await t.ship(), { sent: 1, failed: 0 });
    order = await t.online(2);
    assert.equal(order.fulfilment.shipment.state, "sent");
    assert.equal(magento.shipments.filter((s) => s.orderId === 2).length, 1);
    // MSI source code goes with the shipment.
    assert.deepEqual(magento.shipments.find((s) => s.orderId === 2).body.arguments, { extension_attributes: { source_code: "pune_shop" } });

    // 3. Two workers at once: the job is claimed first, so Magento gets one shipment.
    magento.order(3, [["ML-WIPER-01", 1]]);
    await t.poll();
    await call("online-orders/mg-3/invoice", { picks: [{ itemId: 30, qty: 1 }] }, owner);
    await call("online-orders/mg-3/ship", { courier: "DTDC", tracking: "D3" }, owner);
    const results = await Promise.all([t.ship(), t.ship()]);
    assert.equal(results.reduce((n, r) => n + r.sent, 0), 1);
    assert.equal(magento.shipments.filter((s) => s.orderId === 3).length, 1);
    assert.equal((await t.online(3)).fulfilment.shipment.state, "sent");

    // A claimed job cannot be re-queued mid-send.
    magento.order(4, [["ML-WIPER-01", 1]]);
    await t.poll();
    await call("online-orders/mg-4/invoice", { picks: [{ itemId: 40, qty: 1 }] }, owner);
    await call("online-orders/mg-4/ship", { courier: "DTDC", tracking: "D4" }, owner);
    const job = await getRecord(t.db, "demo", "magentoShipment", "mg-4");
    await putRecord(t.db, "demo", "magentoShipment", { ...job, claimedAt: new Date().toISOString(), nextAt: new Date(Date.now() + 60_000).toISOString() });
    await call("online-orders/mg-4/shipment/retry", {}, owner, 409);
    await call("online-orders/mg-4/ship", { courier: "DTDC", tracking: "D4B" }, owner, 409);
  } finally {
    await t.close();
  }
});

test("MSI: the website quantity stays right before and after an invoiced order ships", async () => {
  const t = await setup();
  const { magento, call, owner, db } = t;
  try {
    await call("online-listings", { productIds: ["filter"], changes: { published: true } }, owner);
    const qty = () => onlineQuantity(db, "demo", "pune", "filter", 0);
    assert.equal(await t.onHand("filter"), 24);
    magento.order(1, [["ML-FILTER-01", 3]]);
    await t.poll();
    // Ordered: POS has 24; MSI reserves 3 itself → push 24 (website shows 24 − 3 = 21).
    assert.equal(await qty(), 24);
    await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 3 }] }, owner);
    // Invoiced in the POS: 21 on the shelf, MSI still reserves 3 → push 21 + 3 = 24 (website 21).
    assert.equal(await t.onHand("filter"), 21);
    assert.equal(await qty(), 24);
    await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "X" }, owner);
    await putRecord(db, "demo", "magentoJob", { id: "filter", productId: "filter", version: 1, nextAt: "9999" });
    assert.deepEqual(await t.ship(), { sent: 1, failed: 0 });
    // Shipped on Magento: MSI took 3 off its source and dropped the reservation → push 21 (website 21).
    assert.equal(await qty(), 21);
    const job = await getRecord(db, "demo", "magentoJob", "filter");
    assert.equal(job!.reason, "online-shipment");
    assert.ok(job!.nextAt <= new Date().toISOString());
    // Polling the shipped order changes nothing.
    await t.poll();
    assert.equal(await qty(), 21);
  } finally {
    await t.close();
  }
});

test("Bank transfer / UPI is paid later: Credit until payment received, then the Magento invoice", async () => {
  const t = await setup();
  const { magento, call, owner } = t;
  try {
    magento.order(1, [["ML-FILTER-01", 2]], { payment: { method: "banktransfer", additional_information: ["Bank Transfer (UPI)"] } });
    await t.poll();
    const packed = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2 }] }, owner);
    assert.deepEqual(packed.invoice.tenders.map((x: any) => x.type), ["Credit"]);
    assert.equal(packed.invoice.cashOnDelivery, false);
    assert.equal(packed.invoice.paymentKind, "bank");
    assert.equal(packed.order.fulfilment.paymentDue, 20000);
    assert.equal(packed.order.fulfilment.magentoInvoice, undefined);
    const customerId = packed.order.fulfilment.customerId;
    const balance = async () => (await call("bootstrap", undefined, owner, 200, "GET")).partyBalances.customers[customerId];
    assert.equal(await balance(), 20000);
    // The reference is required.
    await call("online-orders/mg-1/payment-received", {}, owner, 400);
    await call("online-orders/mg-1/payment-received", { reference: "UPI 4242", amount: 30000 }, owner, 400);
    const paid = await call("online-orders/mg-1/payment-received", { reference: "UPI 4242" }, owner);
    assert.equal(paid.payment.amount, 20000);
    assert.equal(paid.payment.mode, "UPI");
    assert.equal(paid.payment.reference, "UPI 4242");
    assert.equal(paid.payment.invoiceId, packed.invoice.id);
    assert.equal(paid.order.fulfilment.paymentDue, 0);
    assert.equal(paid.order.fulfilment.magentoInvoice.state, "queued");
    assert.equal(await balance(), 0);
    await call("online-orders/mg-1/payment-received", { reference: "again" }, owner, 409);
    assert.deepEqual(await runMagentoInvoices(t.db, { fetch: magento.fetch }), { sent: 1, failed: 0 });
    assert.deepEqual(magento.invoices, [{ orderId: 1, body: { capture: false, notify: false } }]);
    assert.equal((await t.online(1)).fulfilment.magentoInvoice.state, "sent");
    // Magento invoices never take POS stock for these orders.
    await t.poll();
    assert.equal(await t.onHand("filter"), 22);

    // Invoiced in the Magento admin meanwhile: the queued invoice is skipped, not made twice.
    const o2 = magento.order(2, [["ML-WIPER-01", 1]], { payment: { method: "banktransfer" } });
    await t.poll();
    await call("online-orders/mg-2/invoice", { picks: [{ itemId: 20, qty: 1 }] }, owner);
    await call("online-orders/mg-2/payment-received", { reference: "NEFT 77", mode: "Bank transfer" }, owner);
    magento.update(o2, (i) => (i.qty_invoiced = 1));
    assert.deepEqual(await runMagentoInvoices(t.db, { fetch: magento.fetch }), { sent: 1, failed: 0 });
    assert.equal(magento.invoices.length, 1);
    assert.equal((await t.online(2)).fulfilment.magentoInvoice.state, "skipped");
    // Not a bank transfer order.
    magento.order(3, [["ML-WIPER-01", 1]]);
    await t.poll();
    await call("online-orders/mg-3/invoice", { picks: [{ itemId: 30, qty: 1 }] }, owner);
    await call("online-orders/mg-3/payment-received", { reference: "x" }, owner, 409);
  } finally {
    await t.close();
  }
});

test("Cancelled or refunded on Magento after the POS invoice: credit note needed, shipment held, only open units shipped", async () => {
  const t = await setup();
  const { magento, call, owner } = t;
  try {
    const o1 = magento.order(1, [["ML-FILTER-01", 3]]);
    await t.poll();
    const packed = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 3 }] }, owner);
    await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "T1" }, owner);
    // Refunded one unit on the website before the shipment went.
    magento.update(o1, (i) => (i.qty_refunded = 1));
    await t.poll();
    let order = await t.online(1);
    assert.equal(order.fulfilment.creditNoteNeeded.invoiceId, packed.invoice.id);
    assert.deepEqual(order.fulfilment.creditNoteNeeded.lines.map((l: any) => [l.itemId, l.qty]), [[10, 1]]);
    assert.equal(order.fulfilment.shipment.state, "held");
    assert.equal(await getRecord(t.db, "demo", "magentoShipment", "mg-1"), undefined);
    // Reading the order again does not flag it twice.
    await t.poll();
    assert.equal((await t.online(1)).fulfilment.creditNoteNeeded.lines[0].qty, 1);
    await call("online-orders/mg-1/shipment/retry", {}, owner, 409);
    await call("online-orders/mg-1/credit-note/resolve", {}, owner, 409);
    // The return for that invoice clears it.
    await call("shifts/open", { openingCash: 0 }, owner);
    await call(`invoices/${packed.invoice.id}/returns`, {
      transactionId: randomUUID(), reason: "Refunded on website", refundType: "Credit",
      lines: [{ lineId: packed.invoice.lines[0].id, quantity: 1, disposition: "restock" }],
    }, owner);
    order = await call("online-orders/mg-1/credit-note/resolve", {}, owner);
    assert.ok(order.fulfilment.creditNoteNeeded.resolvedAt);
    await call("online-orders/mg-1/shipment/retry", {}, owner);
    assert.deepEqual(await t.ship(), { sent: 1, failed: 0 });
    // Only the two units still open on Magento are shipped.
    assert.deepEqual(magento.shipments[0].body.items, [{ order_item_id: 10, qty: 2 }]);

    // Everything refunded before shipping: nothing is posted to Magento (never a qty 0 shipment).
    const o2 = magento.order(2, [["ML-WIPER-01", 1]]);
    await t.poll();
    await call("online-orders/mg-2/invoice", { picks: [{ itemId: 20, qty: 1 }] }, owner);
    magento.update(o2, (i) => (i.qty_refunded = 1));
    await t.poll();
    await call("online-orders/mg-2/ship", { courier: "Delhivery", tracking: "T2" }, owner, 409);
    await call("online-orders/mg-2/credit-note/resolve", { reason: "Customer keeps nothing; voiding later" }, owner);
    await call("online-orders/mg-2/ship", { courier: "Delhivery", tracking: "T2" }, owner);
    assert.deepEqual(await t.ship(), { sent: 1, failed: 0 });
    assert.equal(magento.shipments.filter((s) => s.orderId === 2).length, 0);
    assert.equal((await t.online(2)).fulfilment.shipment.state, "cancelled");
  } finally {
    await t.close();
  }
});

test("Shipping charge needs a SHIPPING service part, and the POS total equals Magento's grand total", async () => {
  const t = await setup();
  const { magento, call, owner, db } = t;
  try {
    // Row totals with odd paise: 3 × filter for ₹100.01, shipping ₹49.99, grand total ₹150.00.
    magento.order(1, [["ML-FILTER-01", 3]], {
      grand_total: 150,
      shipping_incl_tax: 49.99,
      items: [{ item_id: 10, sku: "ML-FILTER-01", name: "Filter", qty_ordered: 3, qty_invoiced: 0, qty_shipped: 0, qty_canceled: 0, qty_refunded: 0, price_incl_tax: 33.34, row_total_incl_tax: 100.01, discount_amount: 0 }],
    });
    await t.poll();
    const refused = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2, binId: "bin-a1" }, { itemId: 10, qty: 1, binId: "bin-a2" }] }, owner, 409);
    assert.match(refused.error || refused.message, /SKU SHIPPING/);
    const service = await getRecord(db, "demo", "product", "service");
    await putRecord(db, "demo", "product", { ...service, id: "shipping", sku: "SHIPPING", name: "Shipping", hsnSac: "996812", barcodes: [] });
    const { invoice } = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2, binId: "bin-a1" }, { itemId: 10, qty: 1, binId: "bin-a2" }] }, owner);
    assert.equal(invoice.total, 15000);
    assert.equal(invoice.lines.reduce((n: number, l: any) => n + l.total, 0), 15000);
    // The row total is shared over the two bins (6667 + 3334 = 10001); shipping is the last line.
    const parts = invoice.lines.filter((l: any) => l.productId === "filter");
    assert.deepEqual(parts.map((l: any) => l.qty), [2, 1]);
    assert.ok(Math.abs(parts.reduce((n: number, l: any) => n + l.total, 0) - 10001) <= 2);
    assert.equal(invoice.lines[invoice.lines.length - 1].productId, "shipping");
  } finally {
    await t.close();
  }
});

test("COD after a credit note collects less; a void before shipping puts the order back to pick, after shipping blocks collection", async () => {
  const t = await setup();
  const { magento, call, owner } = t;
  const cod = { payment: { method: "cashondelivery", additional_information: ["Cash On Delivery"] } };
  try {
    await call("shifts/open", { openingCash: 0 }, owner);
    // Credit note for one of two units before delivery: only the rest is collected.
    magento.order(1, [["ML-FILTER-01", 2]], cod);
    await t.poll();
    const { invoice } = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2 }] }, owner);
    await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "C1" }, owner);
    await t.ship();
    const credit = await call(`invoices/${invoice.id}/returns`, {
      transactionId: randomUUID(), reason: "One damaged in transit", refundType: "Credit",
      lines: [{ lineId: invoice.lines[0].id, quantity: 1, disposition: "damaged" }],
    }, owner);
    await call("online-orders/mg-1/delivered", { amount: invoice.total }, owner, 400);
    const delivered = await call("online-orders/mg-1/delivered", { reference: "COD remit" }, owner);
    assert.equal(delivered.payment.amount, invoice.total - credit.total);

    // Void before shipping: back to "To pick", units reserved again, invoiced again.
    magento.order(2, [["ML-WIPER-01", 2]], cod);
    await t.poll();
    const first = await call("online-orders/mg-2/invoice", { picks: [{ itemId: 20, qty: 2 }] }, owner);
    assert.equal(await t.onHand("wiper"), 18);
    await call(`invoices/${first.invoice.id}/void`, { reason: "Wrong items packed" }, owner);
    let order = await t.online(2);
    assert.equal(order.fulfilment.invoiceId, undefined);
    assert.equal(order.fulfilment.status, "new");
    assert.equal(order.fulfilment.voidedInvoices[0].invoiceId, first.invoice.id);
    assert.equal(order.lines[0].posInvoiced, 0);
    assert.equal(order.lines[0].reserved, 2);
    assert.equal(await t.onHand("wiper"), 20);
    const second = await call("online-orders/mg-2/invoice", { picks: [{ itemId: 20, qty: 2 }] }, owner);
    assert.notEqual(second.invoice.id, first.invoice.id);

    // Void after the goods left: the order keeps the invoice, marked voided; no COD against it.
    await call("online-orders/mg-2/ship", { courier: "Delhivery", tracking: "C2" }, owner);
    await t.ship();
    await call(`invoices/${second.invoice.id}/void`, { reason: "Customer refused, returned to shop" }, owner);
    order = await t.online(2);
    assert.equal(order.fulfilment.invoiceVoided.invoiceId, second.invoice.id);
    const refused = await call("online-orders/mg-2/delivered", { amount: 100 }, owner, 409);
    assert.match(refused.error || refused.message, /voided/);
    const done = await call("online-orders/mg-2/delivered", {}, owner);
    assert.equal(done.payment, null);
  } finally {
    await t.close();
  }
});
