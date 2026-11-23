import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { addMonths, warrantyUntil } from "../src/hooks/serial-warranty.js";
import { kitAvailability } from "../src/hooks/kits.js";

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]).toString("base64");

test("Workshop: vehicle registry, estimate -> job card -> invoice, kits, serial warranty", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db, {});
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({
        method: method as any,
        url: "/api/v1/" + path,
        payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const get = (path: string, token: string, status = 200) => call(path, undefined, token, status, "GET");
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const manager = await login("manager@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const stockOf = async (productId: string, binId = "bin-a1") =>
      (await get("bootstrap", manager)).stock.find((s: any) => s.productId === productId && s.binId === binId) || { quantity: 0, available: 0 };

    // ---------- vehicles: normalised, unique registration numbers and search ----------
    const swift = await call("customer-vehicles", {
      regNo: "mh 12 ab 1234", customerId: "customer-1", make: "Maruti Suzuki", model: "Swift", year: 2022, fuel: "Petrol", engine: "1.2L", odo: 41000,
    }, cashier);
    assert.equal(swift.regNo, "MH 12 AB 1234");
    assert.equal(swift.regKey, "MH12AB1234");
    const clash = await call("customer-vehicles", { regNo: "MH-12-AB-1234", make: "Honda" }, manager, 409);
    assert.match(clash.error, /already registered/);
    await call("customer-vehicles", { regNo: "MH12" + "AB", make: "Honda" }, manager, 200);
    await call("customer-vehicles", { regNo: "KA 01 X 9", make: "Hyundai", fuel: "Steam" }, manager, 400);
    const found = await get("customer-vehicles?q=" + encodeURIComponent("mh12ab1234"), cashier);
    assert.equal(found.rows[0].id, swift.id);
    assert.equal(found.rows[0].customerName, "Arjun Demo");
    assert.equal((await get("customer-vehicles?q=1234", cashier)).rows[0].id, swift.id);
    assert.deepEqual((await get("customer-vehicles?customerId=customer-1", cashier)).rows.map((v: any) => v.id), [swift.id]);
    assert.equal((await get("customer-vehicles?customerId=nobody", cashier)).rows.length, 0);
    assert.equal((await get("customer-vehicles?q=9000000101", cashier)).rows[0].id, swift.id);
    assert.equal((await get("customer-vehicles/by-reg/MH12AB1234", cashier)).id, swift.id);
    await get("customer-vehicles/by-reg/XX00", cashier, 404);
    // Editing keeps its own number.
    const edited = await call("customer-vehicles", { id: swift.id, variant: "ZXi" }, manager);
    assert.equal(edited.variant, "ZXi");
    assert.equal(edited.make, "Maruti Suzuki");

    // ---------- estimate ----------
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    // A cashier quotes at catalog prices only.
    await call("estimates", { vehicleId: swift.id, lines: [{ productId: "service", qty: 1, unitPrice: 100 }] }, cashier, 403);
    const estimate = await call("estimates", {
      vehicleId: swift.id,
      lines: [
        { productId: "filter", qty: 2 },
        { productId: "service", qty: 1, unitPrice: 40000, description: "Oil change and filter fitting" },
      ],
      validDays: 7,
      notes: "Engine oil leak check",
    }, manager);
    assert.equal(estimate.number, "EST-PUNE-1");
    assert.equal(estimate.customerId, "customer-1", "customer comes from the vehicle");
    assert.equal(estimate.status, "draft");
    // 2 x 285.00 + 400.00 = 970.00, plus 18% GST = 1144.60
    assert.equal(estimate.subtotal, 97000);
    assert.equal(estimate.tax, 17460);
    assert.equal(estimate.total, 114460);
    await call("estimates", { lines: [{ productId: "filter", qty: 1 }, { productId: "filter", qty: 1 }] }, manager, 400);
    assert.equal((await call(`estimates/${estimate.id}/status`, { status: "sent" }, cashier)).status, "sent");

    // ---------- job card from the estimate ----------
    const filterBefore = await stockOf("filter");
    const job = await call(`estimates/${estimate.id}/job`, { bay: "Bay 2", technicianId: "user-inventory", odo: 41250 }, cashier);
    assert.equal(job.number, "JOB-PUNE-1");
    assert.equal(job.status, "checked-in");
    assert.equal(job.lines.find((l: any) => l.productId === "filter").binId, "bin-a1");
    assert.equal(job.total, estimate.total);
    const converted = (await get("bootstrap", manager)).estimates.find((e: any) => e.id === estimate.id);
    assert.equal(converted.status, "converted");
    assert.equal(converted.jobId, job.id);
    await call(`estimates/${estimate.id}/job`, {}, cashier, 409);
    // Check-in ODO updates the vehicle.
    assert.equal((await get(`customer-vehicles/${swift.id}`, cashier)).vehicle.odo, 41250);
    // Parts on the job are reserved, not yet sold.
    const reserved = await stockOf("filter");
    assert.equal(reserved.quantity, filterBefore.quantity);
    assert.equal(reserved.available, filterBefore.available - 2);

    // Status, photos, scanning one more part.
    assert.equal((await call(`jobs/${job.id}/status`, { status: "in-progress" }, cashier)).status, "in-progress");
    await call(`jobs/${job.id}/status`, { status: "delivered" }, cashier, 409);
    const photo = await call("attachments", { contentType: "image/jpeg", data: JPEG, name: "scratch.jpg" }, cashier);
    const withPhoto = await call(`jobs/${job.id}/photos`, { photoIds: [photo.id], tag: "defect", note: "Rear bumper scratch" }, cashier);
    assert.equal(withPhoto.photos[0].tag, "defect");
    const scanned = await call(`jobs/${job.id}/lines`, { lines: [...job.lines, { productId: "bulb", qty: 1 }] }, cashier);
    assert.equal(scanned.lines.length, 3);
    assert.equal(scanned.total, job.total + 35282);
    assert.equal(scanned.linesRevision, 1, "first legacy save starts tracking revisions");
    // Another desk still has the original two-line list. Neither a modern nor
    // an older app may remove the bulb and release its reservation by mistake.
    await call(`jobs/${job.id}/lines`, { expectedLinesRevision: 0, lines: job.lines }, manager, 409);
    await call(`jobs/${job.id}/lines`, { lines: job.lines }, manager, 409);
    const afterConflict = await get("bootstrap", manager);
    assert.deepEqual(afterConflict.jobs.find((j: any) => j.id === job.id).lines, scanned.lines);
    assert.equal(afterConflict.holds.find((h: any) => h.jobId === job.id).cart.lines.find((l: any) => l.productId === "bulb").qty, 1);

    // ---------- one click to a GST invoice ----------
    const invoice = await call(`jobs/${job.id}/invoice`, {
      transactionId: randomUUID(), shiftId: shift.id, tenders: [{ type: "Cash", amount: scanned.total, confirmed: true }],
    }, cashier);
    assert.equal(invoice.jobId, job.id);
    assert.equal(invoice.vehicleId, swift.id);
    assert.equal(invoice.vehicle.regNo, "MH 12 AB 1234");
    assert.equal(invoice.customerId, "customer-1");
    assert.equal(invoice.total, scanned.total, "the invoice charges what the job card shows");
    const labour = invoice.lines.find((l: any) => l.productId === "service");
    assert.equal(labour.unitPrice, 40000, "quoted labour price, not the catalog's 450.00");
    assert.equal(labour.kind, "labour");
    assert.equal(labour.staffId, "user-inventory", "the job's technician is recorded on the line");
    assert.equal(invoice.lines.find((l: any) => l.productId === "filter").kind, "part");
    const sold = await stockOf("filter");
    assert.equal(sold.quantity, filterBefore.quantity - 2);
    assert.equal(sold.available, filterBefore.available - 2, "reservation released when sold");
    const boot = await get("bootstrap", manager);
    const billed = boot.jobs.find((j: any) => j.id === job.id);
    assert.equal(billed.status, "delivered");
    assert.equal(billed.invoiceId, invoice.id);
    assert.equal(billed.holdId, null);
    assert.equal(boot.holds.length, 0);
    await call(`jobs/${job.id}/invoice`, { shiftId: shift.id, tenders: [{ type: "Cash", amount: 1, confirmed: true }] }, cashier, 409);
    const history = await get(`customer-vehicles/${swift.id}`, manager);
    assert.equal(history.invoices[0].id, invoice.id);
    assert.equal(history.jobs[0].id, job.id);

    // A direct job card. Its parked reservation cannot be resumed, re-parked,
    // discarded or billed at the counter: it is billed from the job card.
    const walkIn = await call("jobs", { vehicleId: swift.id, lines: [{ productId: "wiper", qty: 1 }] }, cashier);
    assert.equal(walkIn.number, "JOB-PUNE-2");
    const hold = (await get("bootstrap", cashier)).holds.find((h: any) => h.jobId === walkIn.id);
    const refused = await call("invoices", {
      ...hold.cart, holdId: hold.id, shiftId: shift.id, transactionId: randomUUID(), tenders: [{ type: "Cash", amount: walkIn.total, confirmed: true }],
    }, cashier, 409);
    assert.match(refused.error, /job card/);
    await call("holds", { id: hold.id, cart: hold.cart }, cashier, 409);
    await call(`holds/${hold.id}`, undefined, cashier, 409, "DELETE");
    const counter = await call(`jobs/${walkIn.id}/invoice`, {
      transactionId: randomUUID(), shiftId: shift.id, tenders: [{ type: "Cash", amount: walkIn.total, confirmed: true }],
    }, cashier);
    assert.equal(counter.jobId, walkIn.id);
    assert.equal(counter.vehicleId, swift.id);
    assert.equal((await get("bootstrap", manager)).jobs.find((j: any) => j.id === walkIn.id).invoiceId, counter.id);
    // Cancelling a job releases its reservation (managers only).
    const third = await call("jobs", { lines: [{ productId: "belt", qty: 1 }] }, cashier);
    await call(`jobs/${third.id}/status`, { status: "cancelled" }, cashier, 403);
    await call(`jobs/${third.id}/status`, { status: "cancelled" }, manager);
    assert.equal((await get("bootstrap", manager)).holds.length, 0);

    // ---------- kits ----------
    const kit = await call("products", {
      name: "Brake Service Kit", sku: "KIT-BRAKE", hsnSac: "8708", retailPrice: 250000, taxRate: 2800,
      components: [{ productId: "brake", qty: 1 }, { productId: "brake-fluid", qty: 2 }, { productId: "service", qty: 1 }],
      warrantyMonths: 6,
    }, manager);
    assert.equal(kit.type, "service", "a kit holds no stock itself");
    assert.equal(kit.components.length, 3);
    await call("products", { name: "Loop", components: [{ productId: "brake" }, { productId: "brake" }] }, manager, 400);
    const products = (await get("bootstrap", manager)).products;
    const stockRows = (await get("bootstrap", manager)).stock;
    const brakeBefore = await stockOf("brake"), fluidBefore = await stockOf("brake-fluid");
    assert.equal(kitAvailability(kit, products, stockRows), Math.min(
      stockRows.filter((r: any) => r.productId === "brake").reduce((n: number, r: any) => n + r.available, 0),
      Math.floor(stockRows.filter((r: any) => r.productId === "brake-fluid").reduce((n: number, r: any) => n + r.available, 0) / 2),
    ));
    const kitSale = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id, lines: [{ productId: kit.id, qty: 2 }],
      tenders: [{ type: "Cash", amount: 640000, confirmed: true }],
    }, cashier);
    const kitLine = kitSale.lines[0];
    assert.equal(kitSale.lines.length, 1, "one taxable line for the kit");
    assert.equal(kitLine.kind, "kit");
    assert.equal(kitLine.subtotal, 500000);
    assert.equal(kitLine.tax, 140000, "GST at the kit's own 28% on its own price");
    assert.equal(kitSale.total, 640000);
    assert.deepEqual(kitLine.components.map((c: any) => [c.productId, c.qty]).sort(), [["brake", 2], ["brake-fluid", 4], ["service", 2]]);
    assert.equal((await stockOf("brake")).quantity, brakeBefore.quantity - 2);
    assert.equal((await stockOf("brake-fluid")).quantity, fluidBefore.quantity - 4);
    const ledger = (await db.query("SELECT quantity FROM stock_ledger WHERE reference_id=$1 AND reason='Kit sale'", [kitSale.id])).rows;
    assert.equal(ledger.length, 2);
    // Integration: returning kits puts their stocked components back, per kit returned.
    await call("shifts/open", { openingCash: 0 }, manager);
    const kitBack = await call(`invoices/${kitSale.id}/returns`, {
      transactionId: randomUUID(), reason: "Not fitted", refundType: "Cash",
      lines: [{ lineId: kitLine.id, quantity: 1, disposition: "restock", binId: "bin-a1" }],
    }, manager);
    assert.equal(kitBack.total, 320000);
    assert.deepEqual(kitBack.lines[0].components.map((c: any) => [c.productId, c.qty, c.binId]).sort(),
      [["brake", 1, "bin-a1"], ["brake-fluid", 2, "bin-a1"]]);
    assert.equal((await stockOf("brake")).quantity, brakeBefore.quantity - 1);
    assert.equal((await stockOf("brake-fluid")).quantity, fluidBefore.quantity - 2);
    const kitDamaged = await call(`invoices/${kitSale.id}/returns`, {
      transactionId: randomUUID(), reason: "Box crushed", refundType: "Cash",
      lines: [{ lineId: kitLine.id, quantity: 1, disposition: "damaged" }],
    }, manager);
    const damagedBin = kitDamaged.lines[0].binId;
    assert.ok(damagedBin);
    assert.equal((await stockOf("brake")).quantity, brakeBefore.quantity - 1, "damaged parts are not back on the shelf");
    assert.equal((await stockOf("brake-fluid", damagedBin)).quantity, 2);
    assert.equal((await stockOf("brake", damagedBin)).quantity, 1);
    // Without selling beyond stock, missing components stop the sale.
    const settings = (await getRecord(db, "demo", "settings", "settings"))!;
    await putRecord(db, "demo", "settings", { ...settings, features: { ...(settings.features || {}), negativeStock: false } });
    const tooMany = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id, lines: [{ productId: kit.id, qty: 500 }],
      tenders: [{ type: "Cash", amount: 160000000, confirmed: true }],
    }, cashier, 409);
    assert.match(tooMany.error, /Not enough ML-BRAKE-01/);
    await putRecord(db, "demo", "settings", settings);

    // ---------- serial warranty ----------
    assert.equal(addMonths("2026-01-31", 1), "2026-02-28");
    assert.equal(addMonths("2026-11-21", 24), "2028-11-21");
    assert.equal(warrantyUntil("2026-11-20T20:00:00.000Z", 12), "2027-11-21", "the sale's India business day");
    assert.equal(warrantyUntil("2026-11-20T10:00:00.000Z", 0), null);
    const battery = await call("products", {
      name: "Amaron 45Ah", sku: "AMR-45", hsnSac: "8507", retailPrice: 600000, serialTracked: true, warrantyMonths: 36, universal: true,
    }, manager);
    await db.query("INSERT INTO stock(organization_id,branch_id,product_id,bin_id,quantity) VALUES('demo','pune',$1,'bin-a1',1)", [battery.id]);
    await putRecord(db, "demo", "serial", {
      id: battery.id + ":AMR123", branchId: "pune", productId: battery.id, serial: "AMR123", binId: "bin-a1", status: "available",
    }, "pune");
    const batterySale = await call("invoices", {
      transactionId: randomUUID(), shiftId: shift.id, customerId: "customer-1",
      // The counter's vehicle chip puts the registry id on the fitment vehicle.
      vehicle: { make: "Maruti Suzuki", model: "Swift", year: 2022, customerVehicleId: swift.id },
      lines: [{ productId: battery.id, qty: 1, binId: "bin-a1", serials: ["AMR123"] }],
      tenders: [{ type: "Cash", amount: 708000, confirmed: true }],
    }, cashier);
    const serial = (await getRecord(db, "demo", "serial", battery.id + ":AMR123"))!;
    assert.equal(serial.invoiceId, batterySale.id);
    assert.equal(serial.customerId, "customer-1");
    assert.equal(serial.vehicleId, swift.id);
    assert.equal(serial.soldAt, batterySale.createdAt);
    assert.equal(serial.warrantyUntil, warrantyUntil(batterySale.createdAt, 36));
    const lookup = (await get("serials/lookup?code=amr123", cashier)).rows[0];
    assert.equal(lookup.product.name, "Amaron 45Ah");
    assert.equal(lookup.invoice.number, batterySale.number);
    assert.equal(lookup.customer.name, "Arjun Demo");
    assert.equal(lookup.vehicle.regNo, "MH 12 AB 1234");
    assert.equal(lookup.warranty, "in warranty");
    assert.equal(lookup.canReturn, true);
    assert.deepEqual((await get("serials/lookup?code=NOPE", cashier)).rows, []);

    // A pre-upgrade job has no stored revision. Two updated counters see zero.
    const legacyJob = await call("jobs", {}, manager);
    delete legacyJob.linesRevision;
    await putRecord(db, "demo", "job", legacyJob, legacyJob.branchId);
    const jobPath = `jobs/${legacyJob.id}/lines`;
    const concurrent = await Promise.all([manager, cashier].map((token, i) => app.inject({
      method: "POST", url: "/api/v1/" + jobPath, headers: { authorization: "Bearer " + token },
      payload: { expectedLinesRevision: 0, lines: [{ productId: "service", qty: i + 1 }] },
    })));
    assert.deepEqual(concurrent.map(r => r.statusCode).sort(), [200, 409]);
    const winner = concurrent.find(r => r.statusCode === 200)!.json();
    const appended = await call(jobPath, { lines: [...winner.lines, { productId: "filter", qty: 1 }] }, cashier);
    assert.equal(appended.linesRevision, 2, "a legacy append retains the other counter's work");
    const removed = await call(jobPath, { expectedLinesRevision: 2, lines: winner.lines }, manager);
    assert.equal(removed.linesRevision, 3);
    await call(jobPath, { lines: appended.lines }, cashier, 409);
    const rebased = await call(jobPath, { expectedLinesRevision: 3, lines: [] }, manager);
    assert.deepEqual(rebased.lines, [], "deliberate removal after refresh releases the reservation");
  } finally {
    await app.close();
    await db.close();
  }
});
