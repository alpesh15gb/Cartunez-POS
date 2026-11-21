// UI polish: advances taken against a job card and used when the job is billed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";

test("Job advances: recorded on the job, applied when billing", async () => {
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
    const get = (path: string, token: string) => call(path, undefined, token, 200, "GET");
    const cashier = (await call("auth/login", { email: "cashier@motorline.local", password: "MotorlineDemo123!" })).token;

    const car = await call("customer-vehicles", { regNo: "MH 14 JA 4242", customerId: "customer-1", make: "Honda", model: "City" }, cashier);
    const job = await call("jobs", { vehicleId: car.id, bay: "2" }, cashier);
    const withLines = await call(`jobs/${job.id}/lines`, { lines: [{ productId: "filter", qty: 1 }, { productId: "service", qty: 1 }] }, cashier);

    // Cash advance needs the drawer open.
    await call(`jobs/${job.id}/advances`, { amount: 20000, mode: "Cash" }, cashier, 409);
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    await call(`jobs/${job.id}/advances`, { amount: 0, mode: "Cash" }, cashier, 400);
    const advance = await call(`jobs/${job.id}/advances`, { amount: 20000, mode: "Cash", notes: "Booking" }, cashier);
    assert.equal(advance.jobId, job.id);
    assert.equal(advance.jobNumber, job.number);
    assert.equal(advance.partyId, "customer-1");
    assert.match(advance.notes, /Job JOB-/);
    const boot = await get("bootstrap", cashier);
    assert.ok(boot.partyPayments.some((p: any) => p.id === advance.id && p.jobId === job.id));
    assert.equal((await get("customers/customer-1/summary", cashier)).availableAdvance, 20000);

    // A walk-in job cannot take an advance.
    const walkIn = await call("jobs", { bay: "3" }, cashier);
    await call(`jobs/${walkIn.id}/advances`, { amount: 1000, mode: "Cash" }, cashier, 400);

    // More advance than is held is refused; the held amount plus cash bills the job.
    await call(`jobs/${job.id}/invoice`, {
      transactionId: randomUUID(), shiftId: shift.id,
      tenders: [{ type: "Advance", amount: 20001 }, { type: "Cash", amount: withLines.total - 20001, confirmed: true }],
    }, cashier, 409);
    const invoice = await call(`jobs/${job.id}/invoice`, {
      transactionId: randomUUID(), shiftId: shift.id, expectedTotal: withLines.total,
      tenders: [{ type: "Advance", amount: 20000 }, { type: "Cash", amount: withLines.total - 20000, confirmed: true }],
    }, cashier);
    assert.equal(invoice.advanceApplied, 20000);
    assert.equal(invoice.jobId, job.id);
    assert.equal((await get("customers/customer-1/summary", cashier)).availableAdvance, 0);

    // A billed job takes no more advances.
    await call(`jobs/${job.id}/advances`, { amount: 1000, mode: "Cash" }, cashier, 409);
  } finally {
    await app.close();
    await db.close();
  }
});
