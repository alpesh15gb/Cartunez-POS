// End-to-end business flows: each test walks one loop through the HTTP API and
// checks stock, money, ledgers and records at every step.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { warrantyUntil } from "../src/hooks/serial-warranty.js";
import { pollMagentoOrders } from "../src/magento-orders.js";
import { runMagentoShipments } from "../src/fulfilment.js";

/** A fake Magento: orders feed, ship endpoint (records payloads), product writes. */
function fakeMagento() {
  const orders: any[] = [];
  const shipments: any[] = [];
  const invoices: any[] = [];
  const requests: { method: string; path: string; body: any }[] = [];
  const fetch = (async (url: string | URL, init: any = {}) => {
    const u = new URL(String(url));
    const body = init.body ? JSON.parse(init.body) : undefined;
    requests.push({ method: init.method || "GET", path: u.pathname, body });
    const reply = (status: number, data: unknown) =>
      new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
    if (init.headers?.Authorization !== "Bearer test-token") return reply(401, { message: "Unauthorized" });
    if (u.pathname === "/rest/V1/store/storeConfigs") return reply(200, [{ base_currency_code: "INR" }]);
    if (u.pathname === "/rest/all/V1/orders") {
      const since = u.searchParams.get("searchCriteria[filter_groups][0][filters][0][value]")!;
      const items = orders.filter((o) => o.updated_at >= since);
      return reply(200, { items, total_count: items.length });
    }
    const ship = u.pathname.match(/^\/rest\/V1\/order\/(\d+)\/ship$/);
    if (ship && init.method === "POST") {
      shipments.push({ orderId: Number(ship[1]), body });
      return reply(200, 900 + shipments.length);
    }
    // The fulfilment worker reads the order back (shipped / invoiced quantities) before acting.
    const one = u.pathname.match(/^\/rest\/V1\/orders\/(\d+)$/);
    if (one && (init.method || "GET") === "GET") {
      const o = orders.find((x) => x.entity_id === Number(one[1]));
      if (!o) return reply(404, { message: "Not found" });
      const shippedQty = (itemId: number) => shipments.filter((sh) => sh.orderId === o.entity_id)
        .flatMap((sh) => sh.body?.items || []).filter((i: any) => i.order_item_id === itemId)
        .reduce((n: number, i: any) => n + Number(i.qty || 0), 0);
      return reply(200, {
        ...o,
        items: o.items.map((i: any) => ({ ...i, qty_shipped: (i.qty_shipped || 0) + shippedQty(i.item_id) })),
      });
    }
    const inv = u.pathname.match(/^\/rest\/V1\/order\/(\d+)\/invoice$/);
    if (inv && init.method === "POST") {
      invoices.push({ orderId: Number(inv[1]), body });
      return reply(200, 700 + invoices.length);
    }
    if (u.pathname === "/rest/V1/shipments") return reply(200, { items: [], total_count: 0 });
    if (u.pathname === "/rest/V1/shipment/track" && init.method === "POST") return reply(200, 1);
    if (u.pathname.startsWith("/rest/all/V1/products/")) return reply(200, { id: 1, sku: "x" });
    return reply(404, { message: "Not found" });
  }) as typeof globalThis.fetch;
  let clock = Date.now();
  const stamp = () => new Date((clock = Math.max(Date.now(), clock + 1000))).toISOString().slice(0, 19).replace("T", " ");
  const order = (n: number, items: [string, number][], extra: any = {}) => {
    const o = {
      entity_id: n, increment_id: `20000000${n}`, state: "new", status: "pending",
      created_at: stamp(), updated_at: stamp(),
      customer_firstname: "Meera", customer_lastname: "Iyer", customer_email: `meera${n}@example.com`,
      grand_total: 100 * items.reduce((s, [, q]) => s + q, 0), order_currency_code: "INR",
      payment: { method: "razorpay", additional_information: ["Razorpay"] },
      extension_attributes: { shipping_assignments: [{ shipping: { address: { street: ["5 FC Road"], city: "Pune", postcode: "411004", region: "Maharashtra", region_code: "MH", telephone: "97000000" + n } } }] },
      items: items.map(([sku, qty], i) => ({ item_id: n * 10 + i, sku, name: sku, qty_ordered: qty, qty_invoiced: 0, qty_canceled: 0, qty_refunded: 0, price_incl_tax: 100, row_total_incl_tax: 100 * qty, discount_amount: 0 })),
      ...extra,
    };
    orders.push(o);
    return o;
  };
  const update = (o: any, change: (item: any) => void) => {
    o.items.forEach(change);
    o.updated_at = stamp();
  };
  return { fetch, order, update, shipments, requests };
}

async function setup(options: any = {}) {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db, options);
  const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
    const response = await app.inject({
      method: method as any, url: "/api/v1/" + path, payload: body,
      headers: token ? { authorization: "Bearer " + token } : {},
    });
    assert.equal(response.statusCode, status, `${path}: ${response.body}`);
    return response.json();
  };
  const get = (path: string, token: string, status = 200) => call(path, undefined, token, status, "GET");
  const login = async (role: string) =>
    (await call("auth/login", { email: role + "@motorline.local", password: "MotorlineDemo123!", branchId: "pune" })).token;
  const boot = (token: string) => get("bootstrap", token);
  /** On-hand and available of a part in one bin (or the whole branch). */
  const stock = async (token: string, productId: string, binId?: string) => {
    const rows = (await boot(token)).stock.filter((s: any) => s.productId === productId && (!binId || s.binId === binId));
    return {
      quantity: rows.reduce((n: number, s: any) => n + s.quantity, 0),
      available: rows.reduce((n: number, s: any) => n + s.available, 0),
      reserved: rows.reduce((n: number, s: any) => n + (s.reserved || 0), 0),
    };
  };
  const ledger = async (referenceId: string) =>
    (await db.query("SELECT product_id, bin_id, quantity, reason FROM stock_ledger WHERE reference_id=$1 ORDER BY created_at, id", [referenceId])).rows
      .map((r: any) => [r.product_id, r.bin_id, Number(r.quantity), r.reason]);
  const audits = async (action: string, subject?: string) =>
    (await records(db, "demo", "audit")).filter((a) => a.action === action && (!subject || a.subject === subject));
  const close = async () => {
    await app.close();
    await db.close();
  };
  return { db, app, call, get, login, boot, stock, ledger, audits, close };
}

/** A serial-tracked part received through a purchase order with the given serials. */
async function receiveSerialPart(t: Awaited<ReturnType<typeof setup>>, manager: string, sku: string, serials: string[], extra: any = {}) {
  const product = await t.call("products", {
    name: "Amaron " + sku, sku, hsnSac: "8507", retailPrice: 500000, taxRate: 1800, serialTracked: true,
    warrantyMonths: 24, universal: true, supplierId: "supplier-1", ...extra,
  }, manager);
  const po = await t.call("purchase-orders", {
    supplierId: "supplier-1", lines: [{ productId: product.id, quantity: serials.length, cost: 300000 }],
  }, manager);
  const receipt = await t.call(`purchase-orders/${po.id}/receive`, {
    transactionId: randomUUID(), lines: [{ productId: product.id, quantity: serials.length, binId: "bin-a1", serials }],
  }, manager);
  assert.equal(receipt.lines[0].quantity, serials.length);
  for (const serial of serials)
    assert.equal((await getRecord(t.db, "demo", "serial", product.id + ":" + serial))!.status, "available");
  return product;
}

// ---------------------------------------------------------------------------
test("Loop 1 – shift: PIN, open with float, sale, cash in/out, customer payment, close by denominations", async () => {
  const t = await setup();
  const { call, get, login } = t;
  try {
    const owner = await login("owner");
    const manager = await login("manager");
    // Manager sets the cashier's PIN and enrols this counter for PIN sign-in.
    assert.equal((await call("users/user-cashier/pin", { pin: "4826" }, manager)).hasPin, true);
    const device = await call("devices/enroll", { name: "Counter 1" }, manager);
    const { key } = await call(`devices/${device.id}/pin-key`, {}, manager);
    const tiles = await call("auth/pin-staff", { deviceId: device.id, deviceKey: key });
    assert.ok(tiles.staff.some((s: any) => s.id === "user-cashier"));
    const signedIn = await call("auth/pin-login", { deviceId: device.id, deviceKey: key, userId: "user-cashier", pin: "4826" });
    assert.equal(signedIn.user.id, "user-cashier");
    const cashier = signedIn.token;

    // Open with a ₹1,000 float.
    const shift = await call("shifts/open", { openingCash: 100000 }, cashier);
    assert.equal(shift.userId, "user-cashier");
    assert.equal(shift.openingCash, 100000);

    // A cash sale of ₹200 paid with ₹250 (₹50 change).
    const service = await call("products", { name: "Puncture", sku: "E2E-PUNC", brand: "Shop", category: "Service",
      unit: "Job", retailPrice: 10000, type: "service", taxRate: 0 }, owner);
    const sale = await call("invoices", { transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: service.id, qty: 2 }], tenders: [{ type: "Cash", amount: 25000, confirmed: true }] }, cashier);
    assert.equal(sale.total, 20000);
    assert.equal(sale.change, 5000);
    assert.equal(sale.shiftId, shift.id);

    // Cash in ₹50, cash out ₹20.
    await call(`shifts/${shift.id}/cash-movements`, { transactionId: randomUUID(), direction: "in", amount: 5000, reason: "Change from safe" }, cashier);
    await call(`shifts/${shift.id}/cash-movements`, { transactionId: randomUUID(), direction: "out", amount: 2000, reason: "Courier" }, cashier);
    // A customer pays ₹30 cash on account: it goes through this drawer.
    const payment = await call("party-payments", { partyKind: "customer", partyId: "customer-1", amount: 3000, mode: "Cash" }, cashier);
    assert.equal(payment.shiftId, shift.id);
    assert.equal(payment.direction, "in");
    assert.equal((await t.audits("customer-payment", payment.id)).length, 1);

    const expected = 100000 + 20000 + 5000 - 2000 + 3000; // 126000
    const before = await get(`shifts/${shift.id}/summary`, cashier);
    assert.equal(before.invoices, 1);
    assert.equal(before.gross, 20000);
    assert.equal(before.change, 5000);
    assert.deepEqual(before.tenders, { Cash: 20000 });
    assert.equal(before.cashSales, 20000);
    assert.equal(before.cashIn, 5000 + 3000);
    assert.equal(before.cashOut, 2000);
    assert.equal(before.cashMovements.length, 2);
    assert.equal(before.partyPayments.length, 1);
    assert.equal(before.partyPayments[0].amount, 3000);
    assert.equal(before.expectedCash, expected);

    // Close by note count: 2×500 + 1×200 + 1×50 + 1×10 = ₹1,260, short by nothing.
    const closed = await call(`shifts/${shift.id}/close`, { denominations: { "50000": 2, "20000": 1, "5000": 1, "1000": 1 } }, cashier);
    assert.equal(closed.countedCash, expected);
    assert.equal(closed.expectedCash, expected);
    assert.equal(closed.variance, 0);
    const after = await get(`shifts/${shift.id}/summary`, manager);
    assert.equal(after.closedAt, closed.closedAt);
    assert.equal(after.countedCash, expected);
    assert.equal(after.variance, 0);
    assert.deepEqual(after.denominations, { "50000": 2, "20000": 1, "5000": 1, "1000": 1 });
    assert.equal((await t.audits("shift-close", shift.id)).length, 1);
    // The closed shift takes no more sales.
    await call("invoices", { transactionId: randomUUID(), shiftId: shift.id, lines: [{ productId: service.id, qty: 1 }],
      tenders: [{ type: "Cash", amount: 10000, confirmed: true }] }, cashier, 409);
  } finally {
    await t.close();
  }
});

// ---------------------------------------------------------------------------
test("Loop 2 – walk-in retail: barcode, serial, customer and vehicle, park, resume, split tender", async () => {
  const t = await setup();
  const { call, get, login, boot, stock, ledger } = t;
  try {
    const manager = await login("manager");
    const cashier = await login("cashier");
    const battery = await receiveSerialPart(t, manager, "E2E-BAT", ["SN-A1", "SN-A2"], { barcodes: ["8901234567897"] });
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);

    // Scanning: the counter resolves a barcode against the catalog it downloaded.
    // (There is no server barcode-lookup route; the catalog in bootstrap carries barcodes.)
    const scanned = (await boot(cashier)).products.find((p: any) => (p.barcodes || []).includes("8901234567897"));
    assert.equal(scanned.id, battery.id);
    assert.equal(scanned.serialTracked, true);
    const seededFilter = (await boot(cashier)).products.find((p: any) => (p.barcodes || []).includes("8900000000002"));
    assert.equal(seededFilter.id, "filter");

    // New customer and their registered vehicle.
    const customer = await call("customers", { name: "Kiran Walkin", phone: "9811122233" }, cashier);
    const car = await call("customer-vehicles", { regNo: "MH 14 CD 4321", customerId: customer.id, make: "Hyundai", model: "i20", year: 2021, fuel: "Petrol" }, cashier);
    assert.equal(car.regKey, "MH14CD4321");

    // Park the sale with a name and reg no: the serial unit is reserved.
    const cart = {
      transactionId: randomUUID(),
      customerId: customer.id,
      vehicle: { make: "Hyundai", model: "i20", year: 2021, customerVehicleId: car.id },
      lines: [
        { productId: battery.id, qty: 1, binId: "bin-a1", serials: ["SN-A1"] },
        { productId: "oil", qty: 1, binId: "bin-a1", serials: [] },
      ],
    };
    const before = await stock(cashier, battery.id, "bin-a1");
    const oilBefore = await stock(cashier, "oil", "bin-a1");
    assert.deepEqual([before.quantity, before.available], [2, 2]);
    const hold = await call("holds", { cart, customerName: "Kiran", regNo: "mh14cd4321" }, cashier);
    assert.equal(hold.regNo, "MH14CD4321");
    assert.equal(hold.customerName, "Kiran");
    assert.equal((await stock(cashier, battery.id, "bin-a1")).available, 1);
    assert.equal((await stock(cashier, "oil", "bin-a1")).available, oilBefore.available - 1);

    // Resume from the parked list and check out: Cash + UPI with reference.
    const resumed = (await boot(cashier)).holds.find((h: any) => h.regNo === "MH14CD4321");
    assert.equal(resumed.id, hold.id);
    // battery 5000.00 + universal engine oil 2199.00 = 7199.00 + 18% GST = 8494.82
    const total = Math.round((500000 + 219900) * 1.18);
    await call("invoices", { ...resumed.cart, holdId: resumed.id, shiftId: shift.id,
      tenders: [{ type: "Cash", amount: 36300, confirmed: true }, { type: "UPI", amount: total - 36300, confirmed: true }] }, cashier, 400);
    const invoice = await call("invoices", { ...resumed.cart, holdId: resumed.id, shiftId: shift.id,
      tenders: [{ type: "Cash", amount: 36300, confirmed: true }, { type: "UPI", amount: total - 36300, confirmed: true, reference: "UPI-REF-778" }] }, cashier);
    assert.equal(invoice.total, total);
    assert.equal(invoice.customerId, customer.id);
    assert.deepEqual(invoice.tenders.map((x: any) => [x.type, x.amount, x.reference || ""]),
      [["Cash", 36300, ""], ["UPI", total - 36300, "UPI-REF-778"]]);
    assert.equal(invoice.change || 0, 0);

    // Serial carries the sale, customer, vehicle and warranty.
    const serial = (await getRecord(t.db, "demo", "serial", battery.id + ":SN-A1"))!;
    assert.equal(serial.status, "sold");
    assert.equal(serial.invoiceId, invoice.id);
    assert.equal(serial.customerId, customer.id);
    assert.equal(serial.vehicleId, car.id);
    assert.equal(serial.warrantyUntil, warrantyUntil(invoice.createdAt, 24));
    assert.equal((await getRecord(t.db, "demo", "serial", battery.id + ":SN-A2"))!.status, "available");
    const lookup = (await get("serials/lookup?code=sn-a1", cashier)).rows[0];
    assert.equal(lookup.invoice.number, invoice.number);
    assert.equal(lookup.warranty, "in warranty");

    // Stock down, hold released, ledger written.
    const after = await stock(cashier, battery.id, "bin-a1");
    assert.deepEqual([after.quantity, after.available], [1, 1]);
    const oilAfter = await stock(cashier, "oil", "bin-a1");
    assert.equal(oilAfter.quantity, oilBefore.quantity - 1);
    assert.equal(oilAfter.available, oilBefore.available - 1);
    assert.equal((await boot(cashier)).holds.length, 0);
    assert.deepEqual((await ledger(invoice.id)).sort(), [[battery.id, "bin-a1", -1, "Sale"], ["oil", "bin-a1", -1, "Sale"]].sort());
    const summary = await get(`shifts/${shift.id}/summary`, cashier);
    assert.deepEqual(summary.tenders, { Cash: 36300, UPI: total - 36300 });
    assert.equal(summary.expectedCash, 36300);
    // The vehicle history shows the bill.
    assert.equal((await get(`customer-vehicles/${car.id}`, cashier)).invoices[0].id, invoice.id);
  } finally {
    await t.close();
  }
});

// ---------------------------------------------------------------------------
test("Loop 3 – estimate to job card: check-in, approve, advance, reserved parts, bill with advance, warranty", async () => {
  const t = await setup();
  const { db, call, get, login, boot, stock, ledger } = t;
  try {
    const manager = await login("manager");
    const cashier = await login("cashier");
    const battery = await receiveSerialPart(t, manager, "E2E-JOBBAT", ["JB-1"], { warrantyMonths: 36 });
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    const customer = await call("customers", { name: "Sunil Workshop", phone: "9822200011" }, cashier);

    // Vehicle check-in.
    const car = await call("customer-vehicles", { regNo: "MH 12 XY 7777", customerId: customer.id, make: "Maruti Suzuki", model: "Swift", year: 2020, fuel: "Petrol", odo: 30000 }, cashier);

    // Estimate: 2 filters + labour at a quoted 400.00.
    const estimate = await call("estimates", {
      vehicleId: car.id,
      lines: [{ productId: "filter", qty: 2 }, { productId: "service", qty: 1, unitPrice: 40000 }],
      validDays: 7,
    }, manager);
    assert.equal(estimate.customerId, customer.id);
    assert.equal(estimate.total, 114460);
    const approved = await call(`estimates/${estimate.id}/status`, { status: "approved", approvedBy: "Sunil" }, cashier);
    assert.equal(approved.status, "approved");
    assert.equal(approved.approvedBy, "Sunil");

    const filterBefore = await stock(manager, "filter");
    const job = await call(`estimates/${estimate.id}/job`, { bay: "Bay 1", odo: 30150 }, cashier);
    assert.equal(job.status, "checked-in");
    assert.equal(job.customerId, customer.id);
    assert.equal(job.vehicleId, car.id);
    assert.equal((await get(`customer-vehicles/${car.id}`, cashier)).vehicle.odo, 30150);
    // Parts on the job are reserved, not deducted.
    let filterNow = await stock(manager, "filter");
    assert.equal(filterNow.quantity, filterBefore.quantity);
    assert.equal(filterNow.available, filterBefore.available - 2);

    // Advance collected in cash through the drawer.
    const advance = await call(`customers/${customer.id}/advances`, { amount: 50000, mode: "Cash", notes: "Job " + job.number }, cashier);
    assert.equal(advance.shiftId, shift.id);
    assert.equal((await get(`customers/${customer.id}/summary`, cashier)).availableAdvance, 50000);

    // Add the serial-tracked battery and a bulb to the job: reserved too.
    const withParts = await call(`jobs/${job.id}/lines`, {
      lines: [...job.lines, { productId: battery.id, qty: 1, serials: ["JB-1"] }, { productId: "bulb", qty: 1 }],
    }, cashier);
    assert.equal(withParts.lines.length, 4);
    assert.equal((await stock(manager, battery.id)).available, 0);
    assert.equal((await stock(manager, battery.id)).quantity, 1);
    // The reserved battery cannot be sold at the counter.
    const counter = await call("invoices", { transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: battery.id, qty: 1, binId: "bin-a1", serials: ["JB-1"] }],
      tenders: [{ type: "Cash", amount: 590000, confirmed: true }] }, cashier, 409);
    assert.match(counter.error, /Insufficient stock/);
    // Nor can the job's parked reservation be checked out at the counter.
    const jobHold = (await boot(cashier)).holds.find((h: any) => h.jobId === job.id);
    await call("invoices", { ...jobHold.cart, holdId: jobHold.id, shiftId: shift.id, transactionId: randomUUID(),
      tenders: [{ type: "Cash", amount: withParts.total, confirmed: true }] }, cashier, 409);
    // With selling beyond stock off, reserved filters are not available to the counter either.
    const settings = (await getRecord(db, "demo", "settings", "settings"))!;
    await putRecord(db, "demo", "settings", { ...settings, features: { ...(settings.features || {}), negativeStock: false } });
    filterNow = await stock(manager, "filter", "bin-a1");
    await call("invoices", { transactionId: randomUUID(), shiftId: shift.id,
      lines: [{ productId: "filter", qty: filterNow.available + 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 100000000, confirmed: true }] }, cashier, 409);
    await putRecord(db, "demo", "settings", settings);

    // Bill the job: the advance is applied explicitly as an "Advance" tender.
    // GAP: nothing applies a customer's advance automatically to a job bill;
    // jobs/:id/invoice forwards only the tenders it is given.
    const balance = withParts.total - 50000;
    const invoice = await call(`jobs/${job.id}/invoice`, {
      transactionId: randomUUID(), shiftId: shift.id,
      tenders: [{ type: "Advance", amount: 50000 }, { type: "Cash", amount: balance, confirmed: true }],
    }, cashier);
    assert.equal(invoice.total, withParts.total);
    assert.equal(invoice.advanceApplied, 50000);
    assert.equal(invoice.jobId, job.id);
    assert.equal(invoice.vehicleId, car.id);
    assert.equal(invoice.customerId, customer.id);
    const summary = await get(`customers/${customer.id}/summary`, cashier);
    assert.equal(summary.availableAdvance, 0);
    assert.equal(summary.balance, 0);
    assert.ok(summary.entries.some((e: any) => e.note === "Advance used" && e.debit === 50000));

    // Stock deducted once, reservation released.
    filterNow = await stock(manager, "filter");
    assert.equal(filterNow.quantity, filterBefore.quantity - 2);
    assert.equal(filterNow.available, filterBefore.available - 2);
    assert.equal((await stock(manager, battery.id)).quantity, 0);
    const moves = await ledger(invoice.id);
    assert.equal(moves.length, 3);
    assert.ok(moves.every((m: any) => m[2] < 0 && m[3] === "Sale"));
    const billed = (await boot(manager)).jobs.find((j: any) => j.id === job.id);
    assert.equal(billed.status, "delivered");
    assert.equal(billed.invoiceId, invoice.id);
    assert.equal((await boot(manager)).holds.length, 0);

    // Drawer: advance cash + balance cash.
    const drawer = await get(`shifts/${shift.id}/summary`, cashier);
    assert.equal(drawer.expectedCash, 50000 + balance);
    assert.equal(drawer.tenders.Advance, 50000);

    // Warranty on the battery serial.
    const serial = (await getRecord(db, "demo", "serial", battery.id + ":JB-1"))!;
    assert.equal(serial.status, "sold");
    assert.equal(serial.invoiceId, invoice.id);
    assert.equal(serial.customerId, customer.id);
    assert.equal(serial.vehicleId, car.id);
    assert.equal(serial.warrantyUntil, warrantyUntil(invoice.createdAt, 36));
  } finally {
    await t.close();
  }
});

// ---------------------------------------------------------------------------
test("Loop 4 – returns/RMA: lookup, mixed dispositions, instant exchange, store credit, audit", async () => {
  const t = await setup();
  const { db, call, get, login, stock, ledger, audits } = t;
  try {
    const manager = await login("manager");
    const battery = await receiveSerialPart(t, manager, "E2E-RMABAT", ["RM-1"]);
    const shift = await call("shifts/open", { openingCash: 0 }, manager);
    const customer = await call("customers", { name: "Return Buyer", phone: "9833344455" }, manager);
    const sale = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id, customerId: customer.id,
      lines: [
        { productId: "oil", qty: 2, binId: "bin-a1" },
        { productId: "filter", qty: 1, binId: "bin-a1" },
        { productId: "wiper", qty: 2, binId: "bin-a1" },
        { productId: battery.id, qty: 1, binId: "bin-a1", serials: ["RM-1"] },
      ],
      tenders: [{ type: "Cash", amount: 100000000, confirmed: true }],
    }, manager);
    const line = (productId: string) => sale.lines.find((l: any) => l.productId === productId);

    // Lookup by the receipt code, by phone and by serial.
    assert.equal((await get(`returns/lookup?q=${encodeURIComponent(sale.number)}`, manager))[0].id, sale.id);
    assert.ok((await get("returns/lookup?q=9833344455", manager)).some((i: any) => i.id === sale.id));
    const bySerial = await get("returns/lookup?q=rm-1", manager);
    assert.equal(bySerial[0].id, sale.id);
    assert.equal(bySerial[0].lines.find((l: any) => l.productId === battery.id).returnableQty, 1);

    // Mixed return: filter back on the shelf, one oil damaged, the battery to the supplier (RMA).
    const filterShelf = await stock(manager, "filter", "bin-a1");
    const mixed = await call(`invoices/${sale.id}/returns`, {
      transactionId: randomUUID(), reason: "Customer returned", refundType: "Cash",
      lines: [
        { lineId: line("filter").id, quantity: 1, disposition: "restock" },
        { lineId: line("oil").id, quantity: 1, disposition: "damaged" },
        { lineId: line(battery.id).id, quantity: 1, disposition: "rma", serials: ["RM-1"] },
      ],
    }, manager);
    assert.equal(mixed.condition, "mixed");
    assert.equal((await stock(manager, "filter", "bin-a1")).quantity, filterShelf.quantity + 1);
    assert.equal((await stock(manager, "oil", mixed.lines.find((l: any) => l.productId === "oil").binId)).quantity, 1);
    assert.equal((await stock(manager, battery.id, "bin-warranty")).quantity, 1);
    assert.equal(mixed.warrantyClaimIds.length, 1);
    const claim = (await t.boot(manager)).warrantyClaims.find((c: any) => c.id === mixed.warrantyClaimIds[0]);
    assert.equal(claim.supplierId, "supplier-1");
    assert.equal(claim.status, "open");
    const moves = await ledger(mixed.id);
    assert.equal(moves.length, 3);
    assert.ok(moves.every((m: any) => m[2] === 1 && m[3] === "Sales return"));
    // Cash refund went out of the drawer.
    let drawer = await get(`shifts/${shift.id}/summary`, manager);
    assert.equal(drawer.cashRefunds, mixed.total);
    const lookedUp = (await get(`returns/lookup?q=${encodeURIComponent(sale.number)}`, manager))[0];
    assert.equal(lookedUp.lines.find((l: any) => l.productId === "filter").returnableQty, 0);
    assert.equal(lookedUp.lines.find((l: any) => l.productId === battery.id).returnableQty, 0);

    // Instant exchange: one wiper back, a brake kit out, the customer pays the difference.
    const brakeBefore = await stock(manager, "brake", "bin-a1");
    const wiperBefore = await stock(manager, "wiper", "bin-a1");
    const wiperCredit = line("wiper").total / 2;
    const brakeTotal = Math.round(185000 * 1.18);
    const drawerBefore = drawer.expectedCash;
    const swapped = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id, customerId: customer.id,
      lines: [
        { productId: "brake", qty: 1, binId: "bin-a1" },
        { kind: "returnRef", invoiceId: sale.id, lineId: line("wiper").id, qty: 1, disposition: "restock" },
      ],
      tenders: [{ type: "Cash", amount: brakeTotal - wiperCredit, confirmed: true }],
    }, manager);
    assert.equal(swapped.total, brakeTotal);
    assert.equal(swapped.exchange.credit, wiperCredit);
    assert.equal(swapped.exchange.applied, wiperCredit);
    assert.equal(swapped.exchange.refund, 0);
    assert.equal((await stock(manager, "brake", "bin-a1")).quantity, brakeBefore.quantity - 1);
    assert.equal((await stock(manager, "wiper", "bin-a1")).quantity, wiperBefore.quantity + 1);
    drawer = await get(`shifts/${shift.id}/summary`, manager);
    assert.equal(drawer.expectedCash, drawerBefore + brakeTotal - wiperCredit, "only the net payment enters the drawer");

    // Store credit: the last wiper back to the customer's account.
    const credited = await call(`invoices/${sale.id}/returns`, {
      transactionId: randomUUID(), reason: "Not needed", refundType: "Credit",
      lines: [{ lineId: line("wiper").id, quantity: 1, disposition: "restock" }],
    }, manager);
    assert.equal(credited.refundType, "Credit");
    const account = await get(`customers/${customer.id}/summary`, manager);
    assert.equal(account.availableAdvance, credited.total);
    assert.equal(account.balance, -credited.total);
    assert.equal((await get(`shifts/${shift.id}/summary`, manager)).expectedCash, drawer.expectedCash, "store credit pays no cash");

    // Audit trail.
    assert.equal((await audits("sale", sale.id)).length, 1);
    assert.equal((await audits("sale", swapped.id)).length, 1);
    assert.equal((await audits("return", sale.id)).length, 3, "mixed return, exchange credit note and store credit");
    assert.equal((await audits("warranty", claim.id)).length, 1);
    const returns = (await records(db, "demo", "return", "pune")).filter((r) => r.invoiceId === sale.id);
    assert.deepEqual(returns.map((r) => r.refundType).sort(), ["Cash", "Credit", "Exchange"]);
  } finally {
    await t.close();
  }
});

// ---------------------------------------------------------------------------
test("Loop 5 – procurement: reorder suggestion, draft PO, place, receive at higher cost, apply price, Magento job", async () => {
  const magento = fakeMagento();
  const t = await setup({ fetch: magento.fetch });
  const { db, call, get, login, stock, ledger } = t;
  try {
    const owner = await login("owner");
    const inventory = await login("inventory");
    await call("integrations/magento", { baseUrl: "http://magento.test", token: "test-token", branchId: "pune", enabled: true }, owner);
    await call("online-listings", { productIds: ["filter"], changes: { published: true } }, owner);
    // Clear the publish job so we see what procurement queues.
    await db.query("DELETE FROM records WHERE organization_id='demo' AND kind='magentoJob'");

    await call("products", { id: "filter", reorderLevel: 30 }, owner);
    const suggestion = (await get("bootstrap", owner)).reorderSuggestions.find((s: any) => s.productId === "filter");
    assert.ok(suggestion.suggestedQuantity > 0);
    const drafts = await call("purchase-orders/from-suggestions", {}, inventory);
    const po = drafts.purchaseOrders.find((p: any) => p.lines.some((l: any) => l.productId === "filter"));
    assert.equal(po.status, "draft");
    assert.equal(po.lines[0].quantity, suggestion.suggestedQuantity);
    assert.equal(po.lines[0].cost, 17100);

    const placed = await call(`purchase-orders/${po.id}/place`, {}, inventory);
    assert.equal(placed.status, "open");

    const before = await stock(owner, "filter", "bin-a1");
    const qty = po.lines[0].quantity;
    const receipt = await call(`purchase-orders/${po.id}/receive`, {
      transactionId: randomUUID(), lines: [{ productId: "filter", quantity: qty, binId: "bin-a1", cost: 20000 }],
    }, inventory);
    assert.equal((await stock(owner, "filter", "bin-a1")).quantity, before.quantity + qty);
    assert.deepEqual(await ledger(receipt.id), [["filter", "bin-a1", qty, "Goods receipt"]]);
    assert.equal((await getRecord(db, "demo", "purchaseOrder", po.id))!.status, "received");
    const product = (await getRecord(db, "demo", "product", "filter"))!;
    assert.equal(product.cost, 20000);
    assert.equal(product.lastPurchaseCost, 20000);
    const hike = receipt.lines[0].costHike;
    assert.equal(hike.oldCost, 17100);
    assert.equal(hike.newCost, 20000);
    assert.equal(hike.suggestedPrice, 33400);
    // Receiving moved stock, so the website stock is queued already.
    let job = await getRecord(db, "demo", "magentoJob", "filter");
    assert.ok(job, "goods receipt queues a Magento update");

    const change = (await get("cost-changes", inventory)).changes.find((c: any) => c.productId === "filter");
    assert.equal(change.suggestedPrice, 33400);
    assert.equal(change.status, "open");
    await db.query("DELETE FROM records WHERE organization_id='demo' AND kind='magentoJob'");
    const applied = await call(`cost-changes/${change.id}/apply`, {}, owner);
    assert.equal(applied.status, "priceUpdated");
    assert.equal(applied.newRetailPrice, 33400);
    assert.equal((await getRecord(db, "demo", "product", "filter"))!.retailPrice, 33400);
    job = await getRecord(db, "demo", "magentoJob", "filter");
    assert.equal(job!.reason, "Price change");
    assert.equal((await getRecord(db, "demo", "onlineListing", "filter"))!.sync.state, "pending");
    assert.equal((await get("purchasing/sync-status?productIds=filter", inventory)).parts[0].state, "queued");
    assert.equal((await t.audits("price-change", "filter")).length, 1);
  } finally {
    await t.close();
  }
});

// ---------------------------------------------------------------------------
test("Loop 6 – online fulfilment: import, pick, invoice without a shift, ship, Magento invoice, COD", async () => {
  const magento = fakeMagento();
  const t = await setup({ fetch: magento.fetch });
  const { db, call, get, login } = t;
  try {
    const owner = await login("owner");
    const cashier = await login("cashier");
    // Razorpay is a prepaid gateway; COD and bank transfer stay owed until collected.
    await call("integrations/magento", { baseUrl: "http://magento.test", token: "test-token", branchId: "pune", enabled: true, prepaidMethods: ["razorpay"] }, owner);
    const onHand = async (productId: string) =>
      Number((await db.query("SELECT COALESCE(SUM(quantity),0) q FROM stock WHERE organization_id='demo' AND branch_id='pune' AND product_id=$1", [productId])).rows[0].q);
    const poll = () => pollMagentoOrders(db, { fetch: magento.fetch, organizationId: "demo" });
    const online = (n: number) => getRecord(db, "demo", "onlineOrder", `mg-${n}`);
    const shift = await call("shifts/open", { openingCash: 10000 }, cashier);
    const drawer = async () => (await get(`shifts/${shift.id}/summary`, cashier)).expectedCash;

    // Prepaid order imported: stock reserved, not deducted.
    const startOil = await onHand("oil");
    const o1 = magento.order(1, [["ML-OIL-01", 2]]);
    await poll();
    let order = await online(1);
    assert.equal(order!.posState, "reserved");
    assert.equal(order!.lines[0].reserved, 2);
    assert.equal(await onHand("oil"), startOil);
    const availableOil = async () => (await t.stock(owner, "oil")).available;
    assert.equal(await availableOil(), startOil - 2);

    // Pick list.
    const picks = await get("online-orders/pick-list?ids=mg-1", owner);
    const oilRow = picks.items.find((i: any) => i.productId === "oil");
    assert.equal(oilRow.qty, 2);
    assert.equal(oilRow.bins[0].binId, "bin-a1");

    // Invoice & pack: online channel, online till, Online tender, no drawer cash.
    const packed = await call("online-orders/mg-1/invoice", { picks: [{ itemId: 10, qty: 2, binId: "bin-a1" }] }, owner);
    const invoice = packed.invoice;
    assert.equal(invoice.channel, "online");
    assert.equal(invoice.shiftId, "online-shift-pune");
    assert.deepEqual(invoice.tenders.map((x: any) => x.type), ["Online"]);
    assert.equal(await onHand("oil"), startOil - 2);
    assert.equal(await availableOil(), startOil - 2);
    assert.deepEqual(await t.ledger(invoice.id), [["oil", "bin-a1", -2, "Sale"]]);
    assert.equal(await drawer(), 10000, "online sale is not drawer cash");
    assert.equal((await t.boot(owner)).shifts.filter((s: any) => s.userId === "user-owner").length, 0, "no shift opened for the owner");

    // Ship with tracking; the worker pushes the shipment to Magento.
    const shipped = await call("online-orders/mg-1/ship", { courier: "Delhivery", tracking: "DLV-E2E-1" }, owner);
    assert.equal(shipped.fulfilment.shipment.state, "queued");
    assert.deepEqual(await runMagentoShipments(db, { fetch: magento.fetch }), { sent: 1, failed: 0 });
    assert.equal(magento.shipments.length, 1);
    assert.equal(magento.shipments[0].orderId, 1);
    assert.deepEqual(magento.shipments[0].body.items, [{ order_item_id: 10, qty: 2 }]);
    assert.deepEqual(magento.shipments[0].body.tracks, [{ track_number: "DLV-E2E-1", title: "Delhivery", carrier_code: "custom" }]);
    const shipRequest = magento.requests.find((r) => r.method === "POST" && r.path === "/rest/V1/order/1/ship")!;
    assert.deepEqual(shipRequest.body, magento.shipments[0].body);
    order = await online(1);
    assert.equal(order!.fulfilment.status, "shipped");

    // Magento later invoices and ships: no second deduction.
    magento.update(o1, (i) => { i.qty_invoiced = 2; i.qty_shipped = 2; });
    await poll();
    assert.equal(await onHand("oil"), startOil - 2);
    assert.deepEqual(await t.ledger(invoice.id), [["oil", "bin-a1", -2, "Sale"]]);
    assert.equal((await online(1))!.lines[0].reserved, 0);
    assert.equal(await availableOil(), startOil - 2);

    // Cash on delivery: on account until delivered, then the payment is recorded.
    magento.order(2, [["ML-WIPER-01", 1]], { payment: { method: "cashondelivery", additional_information: ["Cash On Delivery"] } });
    await poll();
    const cod = await call("online-orders/mg-2/invoice", { picks: [{ itemId: 20, qty: 1 }] }, owner);
    assert.deepEqual(cod.invoice.tenders.map((x: any) => x.type), ["Credit"]);
    const customerId = cod.order.fulfilment.customerId;
    assert.equal((await t.boot(owner)).partyBalances.customers[customerId], cod.invoice.total);
    await call("online-orders/mg-2/ship", { courier: "Blue Dart", tracking: "BD-E2E" }, owner);
    await runMagentoShipments(db, { fetch: magento.fetch });
    const paid = await call("online-orders/mg-2/delivered", { mode: "Bank transfer", reference: "COD remit 9" }, owner);
    assert.equal(paid.payment.amount, cod.invoice.total);
    assert.equal(paid.payment.invoiceId, cod.invoice.id);
    assert.equal(paid.payment.shiftId, null);
    assert.equal(paid.order.fulfilment.codDue, 0);
    assert.equal((await t.boot(owner)).partyBalances.customers[customerId], 0);
    assert.equal(await drawer(), 10000, "COD remittance does not touch the counter drawer");
    const payments = (await records(db, "demo", "partyPayment", "pune")).filter((p) => p.partyId === customerId);
    assert.equal(payments.length, 1);
  } finally {
    await t.close();
  }
});
