// WS-E: the POS invoices website orders: pick, invoice & pack through the
// checkout pipeline (online till, no cash shift), ship with tracking via the
// worker (retried), cash on delivery collected later; Magento invoices never
// take the stock a second time.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { pollMagentoOrders } from "../src/magento-orders.js";
import { runMagentoShipments, runMagentoInvoices, gstStateCode, isCashOnDelivery, paymentKind, shares } from "../src/fulfilment.js";
import { fakeMagento } from "./fake-magento-shop.js";

test("delivery state and payment method helpers", () => {
  assert.equal(gstStateCode("MH"), "27");
  assert.equal(gstStateCode("", "Karnataka"), "29");
  assert.equal(gstStateCode("XX", "Nowhere"), "");
  assert.equal(isCashOnDelivery({ method: "cashondelivery" }), true);
  assert.equal(isCashOnDelivery({ method: "razorpay", title: "Pay online" }), false);
  // Only gateway methods named in the settings are paid; bank transfer / UPI is paid later.
  assert.equal(paymentKind({ method: "banktransfer" }), "bank");
  assert.equal(paymentKind({ method: "razorpay" }), "bank");
  assert.equal(paymentKind({ method: "razorpay" }, { prepaidMethods: ["razorpay"] }), "prepaid");
  assert.equal(paymentKind({ method: "cashondelivery" }, { prepaidMethods: ["razorpay"] }), "cod");
  // Row totals shared over bins: the last share takes the residual paise.
  assert.deepEqual(shares(10000, [1, 1, 1]), [3333, 3334, 3333]);
  assert.deepEqual(shares(10001, [2, 1]), [6667, 3334]);
});


test("Online fulfilment: pick, invoice & pack without a shift, ship with retries, COD collected on delivery", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const magento = fakeMagento();
  const app = await createApp(db, { fetch: magento.fetch });
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({ method: method as any, url: "/api/v1/" + path, payload: body, headers: token ? { authorization: "Bearer " + token } : {} });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const boot = (token: string) => call("bootstrap", undefined, token, 200, "GET");
    const onHand = async (productId: string) =>
      Number((await db.query("SELECT COALESCE(SUM(quantity),0) q FROM stock WHERE organization_id='demo' AND branch_id='pune' AND product_id=$1", [productId])).rows[0].q);
    const available = async (productId: string) =>
      (await boot(owner)).stock.filter((s: any) => s.productId === productId).reduce((n: number, s: any) => n + s.available, 0);
    const poll = () => pollMagentoOrders(db, { fetch: magento.fetch, organizationId: "demo" });
    const online = (n: number) => getRecord(db, "demo", "onlineOrder", `mg-${n}`);
    await call("integrations/magento", { baseUrl: "http://magento.test", token: "test-token", branchId: "pune", enabled: true, prepaidMethods: "razorpay" }, owner);

    // A prepaid order: stock reserved, and a Magento invoice no longer takes it.
    const o1 = magento.order(1, [["ML-FILTER-01", 3]]);
    await poll();
    let order = await online(1);
    assert.equal(order!.mode, "pos");
    assert.equal(order!.lines[0].reserved, 3);
    magento.update(o1, (i) => (i.qty_invoiced = 3));
    await poll();
    order = await online(1);
    assert.equal(order!.posState, "reserved");
    assert.equal(await onHand("filter"), 24);
    assert.equal(await available("filter"), 21);

    // Pick list for a batch of orders.
    magento.order(2, [["ML-FILTER-01", 1], ["ML-WIPER-01", 2]], { payment: { method: "cashondelivery", additional_information: ["Cash On Delivery"] } });
    await poll();
    const picks = await call("online-orders/pick-list?ids=mg-1,mg-2", undefined, owner, 200, "GET");
    assert.equal(picks.orders.length, 2);
    const filterRow = picks.items.find((i: any) => i.productId === "filter");
    assert.equal(filterRow.qty, 4);
    assert.deepEqual(filterRow.orders.map((o: any) => o.qty), [3, 1]);
    assert.equal(filterRow.bins[0].binId, "bin-a1");
    await call("online-orders/pick-list?ids=mg-1", undefined, cashier, 403, "GET");

    // Invoice & pack needs every unit picked.
    await call("online-orders/mg-1/invoice", { picks: [] }, owner, 400);
    await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2 }] }, owner, 409);
    await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 3 }] }, cashier, 403);
    // The owner has no open shift: the online till is used.
    assert.equal((await boot(owner)).shifts.length, 0);
    const packed = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 3, binId: "bin-a1" }] }, owner);
    const invoice = packed.invoice;
    assert.equal(invoice.channel, "online");
    assert.equal(invoice.shiftId, "online-shift-pune");
    assert.equal(invoice.onlineOrderNumber, "100000001");
    assert.deepEqual(invoice.tenders.map((t: any) => t.type), ["Online"]);
    assert.equal(invoice.tenders[0].amount, invoice.total);
    // Priced at what the customer paid on the website (Rs 100 incl. 18% GST each).
    assert.equal(invoice.lines[0].unitPrice, 8475);
    assert.ok(Math.abs(invoice.total - 30000) <= 3);
    assert.equal(packed.order.posState, "sold");
    assert.equal(packed.order.fulfilment.status, "packed");
    assert.equal(await onHand("filter"), 21);
    assert.equal(await available("filter"), 20); // order 2 still holds one
    await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 3 }] }, owner, 409);
    // Not a cash drawer: no shift appears and drawer cash is untouched.
    const after = await boot(owner);
    assert.equal(after.shifts.length, 0);
    assert.ok(after.invoices.some((i: any) => i.id === invoice.id));

    // The counter cannot use the online till or the Online tender.
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    const counterSale = (shiftId: string, type: string, token = cashier, status = 400) =>
      call("invoices", { transactionId: randomUUID(), shiftId, lines: [{ productId: "oil", qty: 1, binId: "bin-a1" }], tenders: [{ type, amount: 10000000, confirmed: true }] }, token, status);
    await counterSale(shift.id, "Online");
    await counterSale("online-shift-pune", "Cash", owner, 409);

    // Ship: the shipment is queued, Magento fails once, then the retry sends it with tracking.
    await call("online-orders/mg-2/ship", { courier: "Delhivery", tracking: "X1" }, owner, 409); // not invoiced yet
    await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "" }, owner, 400);
    let shipped = await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "DLV123" }, owner);
    assert.equal(shipped.fulfilment.shipment.state, "queued");
    assert.ok(await getRecord(db, "demo", "magentoShipment", "mg-1"));
    magento.failShipments(1);
    assert.deepEqual(await runMagentoShipments(db, { fetch: magento.fetch }), { sent: 0, failed: 1 });
    order = await online(1);
    assert.equal(order!.fulfilment.shipment.state, "error");
    assert.match(order!.fulfilment.shipment.error, /busy/);
    // Backed off: not retried straight away.
    assert.deepEqual(await runMagentoShipments(db, { fetch: magento.fetch }), { sent: 0, failed: 0 });
    await call("online-orders/mg-1/shipment/retry", {}, owner);
    // o1 was invoiced on Magento already (gateway), so the queued Magento invoice is skipped.
    assert.deepEqual(await call("online-orders/shipments/push", {}, owner), { sent: 1, failed: 0, invoices: { sent: 1, failed: 0 } });
    assert.equal(magento.invoices.length, 0);
    assert.equal((await online(1))!.fulfilment.magentoInvoice.state, "skipped");
    order = await online(1);
    assert.equal(order!.fulfilment.shipment.state, "sent");
    assert.equal(order!.fulfilment.status, "shipped");
    assert.equal(await getRecord(db, "demo", "magentoShipment", "mg-1"), undefined);
    assert.deepEqual(magento.shipments[0].body.tracks, [{ track_number: "DLV123", title: "Delhivery", carrier_code: "custom" }]);
    assert.deepEqual(magento.shipments[0].body.items, [{ order_item_id: 10, qty: 3 }]);
    assert.equal(magento.shipments[0].orderId, 1);
    await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "AGAIN" }, owner, 409);
    // Magento shipped it: reading the order again takes no stock a second time.
    await poll();
    assert.equal(await onHand("filter"), 21);
    assert.equal((await online(1))!.lines[0].reserved, 0);
    assert.equal((await online(1))!.lines[0].shipped, 3);
    const delivered = await call("online-orders/mg-1/delivered", {}, owner);
    assert.equal(delivered.payment, null);

    // Cash on delivery: sold on the customer's account until the courier pays.
    const cod = await call("online-orders/mg-2/invoice", { picks: [{ itemId: 20, qty: 1 }, { itemId: 21, qty: 2 }] }, owner);
    assert.deepEqual(cod.invoice.tenders.map((t: any) => t.type), ["Credit"]);
    assert.equal(cod.invoice.cashOnDelivery, true);
    const customerId = cod.order.fulfilment.customerId;
    assert.equal((await boot(owner)).partyBalances.customers[customerId], cod.invoice.total);
    await call("online-orders/mg-2/delivered", {}, owner, 409); // not shipped yet
    await call("online-orders/mg-2/ship", { courier: "Blue Dart", tracking: "BD9" }, owner);
    await runMagentoShipments(db, { fetch: magento.fetch });
    const paid = await call("online-orders/mg-2/delivered", { mode: "Bank transfer", reference: "Remittance 55" }, owner);
    assert.equal(paid.payment.amount, cod.invoice.total);
    assert.equal(paid.payment.invoiceId, cod.invoice.id);
    assert.equal(paid.payment.shiftId, null);
    assert.equal(paid.order.fulfilment.codDue, 0);
    assert.equal((await boot(owner)).partyBalances.customers[customerId], 0);
    await call("online-orders/mg-2/delivered", {}, owner, 409);
    // COD delivered: the Magento invoice is made (no capture, no email).
    assert.equal(paid.order.fulfilment.magentoInvoice.state, "queued");
    assert.deepEqual(await runMagentoInvoices(db, { fetch: magento.fetch }), { sent: 1, failed: 0 });
    assert.deepEqual(magento.invoices, [{ orderId: 2, body: { capture: false, notify: false } }]);
    assert.equal((await online(2))!.fulfilment.magentoInvoice.state, "sent");
  } finally {
    await app.close();
    await db.close();
  }
});
