// WS-C (workshop): estimates, job cards and billing a job.
//
// estimate (EST-...) -> approved -> job card (JOB-...) -> parts scanned on ->
// one-click GST invoice through the normal checkout (finalizeSale) with
// invoice.jobId / invoice.vehicleId.
//
// Lines on both documents: { id, productId, kind: part|labour|service|kit, qty,
// unitPrice, description, staffId, binId?, serials? }. Prices default to the
// catalog retail price; only a manager may quote a different price. The quoted
// price is what the invoice charges when the job is billed from its job card.
//
// Reserving stock: a job's lines are kept as a parked sale (a `hold` record
// with `jobId`), so every stock screen, the website stock feed and checkout
// already count them as reserved. The hold is rewritten when the job's lines
// change and released when the job is billed or cancelled.
import type { FastifyInstance } from "fastify";
import { randomUUID } from "node:crypto";
import type { Database, RecordData } from "../db.js";
import type { Post } from "./types.js";
import { getRecord, putRecord, records } from "../db.js";
import { type Actor, allow, audit, fail, heldUnits, id, integer, inventory, multiline, now, reservingHolds, roundRatio, scoped, text } from "../domain.js";
import { reserveKitComponents } from "../hooks/kit-reserve.js";
import { nextNumber } from "../number-series.js";
import { invoiceProfile, noTax } from "../settings.js";
import { finalizeSale, JOB_INVOICE } from "../sales.js";
import { queueMagentoSync } from "../online-queue.js";
import { registerSaleHook } from "../sale-pipeline.js";
import type { SaleHook } from "../sale-types.js";
import { fitmentVehicle } from "./vehicles.js";
import { advanceMovement } from "./customers.js";

const SELLERS = ["owner", "manager", "cashier"];
const WORKSHOP = ["owner", "manager", "cashier", "inventory"];
export const JOB_STATUSES = ["checked-in", "in-progress", "waiting-parts", "ready", "delivered", "cancelled"] as const;
export const ESTIMATE_STATUSES = ["draft", "sent", "approved", "rejected", "converted"] as const;
const MAX_LINES = 100;
const MAX_JOB_PHOTOS = 30;

type Line = RecordData;

/** Lines as the user sent them, checked against the catalog (and stock for job parts). */
async function documentLines(
  db: Database,
  actor: Actor,
  inputs: unknown,
  options: { job?: RecordData; previous?: Line[] } = {},
): Promise<Line[]> {
  if (!Array.isArray(inputs)) fail("Add the parts and labour as a list.");
  if (inputs.length > MAX_LINES) fail(`A document can have ${MAX_LINES} lines at most.`);
  const manager = ["owner", "manager"].includes(actor.role);
  const settings = (await getRecord(db, actor.organizationId, "settings", "settings"))!;
  const sellBeyondStock = settings.features?.negativeStock !== false;
  const stock = options.job ? await inventory(db, actor) : [];
  const ownHold = options.job?.holdId ? await getRecord(db, actor.organizationId, "hold", options.job.holdId) : undefined;
  const sellable = options.job
    ? (await records(db, actor.organizationId, "location", actor.branchId)).filter((b) => b.kind === "sellable")
    : [];
  // Serials another open job has already reserved.
  const reservedSerials = new Set<string>();
  if (options.job)
    for (const hold of await reservingHolds(db, actor.organizationId, actor.branchId))
      if (hold.id !== ownHold?.id)
        for (const line of hold.cart?.lines || [])
          for (const serial of line.serials || []) reservedSerials.add(line.productId + ":" + serial);
  // What this job's own reservation (parts and kit components) holds is free to it.
  const free = (productId: string, binId: string) =>
    (stock.find((row) => row.productId === productId && row.binId === binId)?.available || 0) +
    heldUnits(ownHold?.cart?.lines, productId, binId);
  const lines: Line[] = [];
  const taken = new Map<string, number>();
  for (const raw of inputs as any[]) {
    const product = await scoped(db, actor, "product", text(raw?.productId, "part or labour", true, 200));
    if (product.salesStopped) fail(`New sales are stopped for ${product.sku}.`, 409);
    const qty = integer(raw.qty ?? 1, "Quantity", 1, 9999);
    const before = (options.previous || []).find((line) => line.id === raw.id && line.productId === product.id);
    let unitPrice = product.retailPrice;
    if (raw.unitPrice !== undefined && raw.unitPrice !== null && raw.unitPrice !== "") {
      const asked = integer(raw.unitPrice, "Price", 0);
      if (asked !== product.retailPrice && asked !== before?.unitPrice && !manager)
        fail("Only a manager can quote a price different from the catalog.", 403);
      unitPrice = asked;
    }
    const kind = product.components?.length
      ? "kit"
      : product.type === "service"
        ? (raw.kind === "service" ? "service" : "labour")
        : "part";
    let staffId: string | undefined;
    if (raw.staffId) {
      staffId = text(raw.staffId, "staff member", true, 200);
      const user = await getRecord(db, actor.organizationId, "user", staffId);
      if (!user || user.active === false) fail("Choose a staff member from this shop.");
    }
    const line: Line = {
      id: typeof raw.id === "string" && /^[\w-]{1,80}$/.test(raw.id) ? raw.id : id("jline"),
      productId: product.id,
      sku: product.sku,
      name: product.name,
      kind,
      qty,
      unitPrice,
      taxRate: noTax(settings) ? 0 : product.taxRate,
      coreCharge: product.coreCharge || 0,
      description: text(raw.description || "", "line note", false, 200),
      ...(staffId ? { staffId } : {}),
    };
    if (options.job && kind === "part") {
      // Parts on a job come out of a sellable bin (the fullest one unless chosen).
      let binId = raw.binId ? text(raw.binId, "bin", true, 200) : "";
      if (binId) {
        const bin = await scoped(db, actor, "location", binId);
        if (bin.kind !== "sellable") fail("Job parts must come from a sellable bin.");
      } else {
        const best = [...sellable].sort((a, b) => free(product.id, b.id) - free(product.id, a.id))[0];
        if (!best) fail("Add a sellable bin before putting parts on a job.");
        binId = best.id;
      }
      const key = product.id + "|" + binId;
      const need = (taken.get(key) || 0) + qty;
      taken.set(key, need);
      if ((!sellBeyondStock || product.serialTracked) && free(product.id, binId) < need)
        fail(`Not enough ${product.sku} in the selected bin to reserve for this job.`, 409);
      const serials: string[] = [];
      if (raw.serials !== undefined && !Array.isArray(raw.serials)) fail("Serial numbers must be a list.");
      for (const value of raw.serials || []) {
        if (!product.serialTracked) fail(`${product.sku} does not track serial numbers.`);
        const serial = text(value, "serial number", true, 100);
        if (serials.includes(serial)) fail(`Serial ${serial} is listed twice.`);
        const record = await getRecord(db, actor.organizationId, "serial", product.id + ":" + serial);
        if (!record || record.branchId !== actor.branchId || record.status !== "available" || record.binId !== binId)
          fail(`Serial ${serial} is not in stock in the selected bin.`, 409);
        if (reservedSerials.has(product.id + ":" + serial)) fail(`Serial ${serial} is already on another job or parked sale.`, 409);
        serials.push(serial);
      }
      if (serials.length > qty) fail(`Scan at most ${qty} serial numbers for ${product.sku}.`);
      line.binId = binId;
      line.serials = serials;
    }
    // Checkout takes each item (and bin) once, so the document does too.
    if (lines.some((other) => other.productId === line.productId && (other.binId || "") === (line.binId || "")))
      fail(`${product.name} is listed twice. Change the quantity on one line instead.`);
    lines.push(line);
  }
  // Money and stock review: a kit on a job card reserves its stocked components
  // (after the plain parts, which take their bins first).
  if (options.job)
    for (const line of lines) {
      if (line.kind !== "kit") continue;
      const kit = await scoped(db, actor, "product", line.productId);
      line.components = await reserveKitComponents(db, actor, kit, line.qty, {
        free, taken, bins: sellable.map((bin) => bin.id), sellBeyondStock,
      });
    }
  return lines;
}

/** Same arithmetic as checkout (no bill discount): tax per line, core deposits, rounding. */
export function documentTotals(settings: RecordData, branch: RecordData | undefined, lines: Line[]) {
  const inclusive = invoiceProfile(settings, branch || {}).taxMode === "inclusive";
  let subtotal = 0, tax = 0, core = 0;
  for (const line of lines) {
    const amount = line.unitPrice * line.qty;
    const lineTax = inclusive
      ? amount - roundRatio(amount, 10000, 10000 + line.taxRate)
      : roundRatio(amount, line.taxRate, 10000);
    subtotal += amount;
    tax += lineTax;
    core += (line.coreCharge || 0) * line.qty;
  }
  const unrounded = subtotal + (inclusive ? 0 : tax) + core;
  const increment = settings.roundingIncrement || 1;
  const total = roundRatio(unrounded, 1, increment) * increment;
  return { subtotal, tax, core, rounding: total - unrounded, total };
}

async function withTotals(db: Database, actor: Actor, document: RecordData) {
  const settings = (await getRecord(db, actor.organizationId, "settings", "settings"))!;
  const branch = await getRecord(db, actor.organizationId, "branch", actor.branchId);
  Object.assign(document, documentTotals(settings, branch, document.lines));
  return document;
}

async function partyRefs(db: Database, actor: Actor, body: any, previous?: RecordData) {
  const customerId = body.customerId === undefined ? previous?.customerId || null : body.customerId || null;
  if (customerId) await scoped(db, actor, "customer", customerId);
  let vehicleId = body.vehicleId === undefined ? previous?.vehicleId || null : body.vehicleId || null;
  let vehicle: RecordData | undefined;
  if (vehicleId) vehicle = await scoped(db, actor, "customerVehicle", vehicleId);
  return { customerId: customerId || vehicle?.customerId || null, vehicleId, vehicle };
}

const day = (value: unknown, label: string) => {
  const date = text(value, label, true, 30).slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date))) fail(`Enter a valid ${label}.`);
  return date;
};

/** Keeps the job's parked-sale reservation in step with its lines. */
async function syncJobHold(db: Database, actor: Actor, job: RecordData) {
  const previous = job.holdId ? await getRecord(db, actor.organizationId, "hold", job.holdId) : undefined;
  const open = !job.invoiceId && job.status !== "cancelled" && job.status !== "delivered" && job.lines.length > 0;
  const touched = [...(previous?.cart?.lines || []), ...job.lines].map((line: any) => line.productId);
  if (!open) {
    if (previous)
      await db.query("DELETE FROM records WHERE organization_id=$1 AND kind='hold' AND id=$2", [actor.organizationId, previous.id]);
    job.holdId = null;
  } else {
    const hold = {
      id: previous?.id || id("hold"),
      branchId: actor.branchId,
      userId: previous?.userId || actor.id,
      jobId: job.id,
      cart: {
        transactionId: randomUUID(),
        // Resuming this at the counter bills the job at catalog prices; the
        // job card's "Bill job" charges the quoted prices.
        lines: job.lines.map((line: Line) => ({
          productId: line.productId,
          qty: line.qty,
          ...(line.binId ? { binId: line.binId, serials: line.serials || [] } : {}),
          ...(line.components?.length ? { components: line.components } : {}),
          ...(line.staffId ? { staffId: line.staffId } : {}),
        })),
        priceLevel: "retail",
        discount: 0,
        vehicle: null,
        customerId: job.customerId || "",
        shiftId: "",
        jobId: job.id,
        vehicleId: job.vehicleId || null,
        note: `Job ${job.number}`,
      },
      createdAt: previous?.createdAt || now(),
    };
    await putRecord(db, actor.organizationId, "hold", hold, actor.branchId);
    job.holdId = hold.id;
  }
  if (touched.length) await queueMagentoSync(db, actor.organizationId, [...new Set(touched)], "hold", actor.branchId);
}

/**
 * Voiding a job's invoice (routes/sales.ts) puts the job back to "ready": the
 * invoice link is cleared, its parts are reserved again from the stock the void
 * returned, and it can be billed again from the job card. A later partial
 * return does not reopen the job (the work was done).
 */
export async function reopenVoidedJob(db: Database, actor: Actor, invoice: RecordData) {
  const job = await getRecord(db, actor.organizationId, "job", String(invoice.jobId));
  if (!job || job.invoiceId !== invoice.id) return;
  job.invoiceId = null;
  job.invoiceNumber = null;
  job.billedTotal = null;
  job.deliveredAt = null;
  job.status = "ready";
  job.history = [...(job.history || []), historyEntry(actor, "ready", `Invoice ${invoice.number} voided`)];
  job.updatedAt = now();
  await syncJobHold(db, actor, job);
  await putRecord(db, actor.organizationId, "job", job, actor.branchId);
  const estimate = job.estimateId ? await getRecord(db, actor.organizationId, "estimate", job.estimateId) : undefined;
  if (estimate && estimate.invoiceId === invoice.id) {
    estimate.invoiceId = null;
    await putRecord(db, actor.organizationId, "estimate", estimate, actor.branchId);
  }
  await audit(db, actor, "job", job.id, `Job reopened: invoice ${invoice.number} voided`, { number: job.number });
}

function historyEntry(actor: Actor, status: string, note = "") {
  return { status, at: now(), by: actor.id, ...(note ? { note } : {}) };
}

async function photosFrom(db: Database, actor: Actor, ids: unknown, tag: string, note: string) {
  if (!Array.isArray(ids) || !ids.length) fail("Choose the photos to attach.");
  const photos = [];
  for (const fileId of ids) {
    const file = await getRecord(db, actor.organizationId, "attachment", String(fileId));
    if (!file) fail("A photo was not uploaded. Add it again.");
    photos.push({ id: file.id, contentType: file.contentType, name: file.name || "", tag, note, at: now(), by: actor.id });
  }
  return photos;
}

/** Creates a job card (from an estimate or directly). */
async function createJob(db: Database, actor: Actor, body: any, estimate?: RecordData) {
  const refs = await partyRefs(db, actor, estimate ? { customerId: estimate.customerId, vehicleId: estimate.vehicleId, ...pick(body, ["customerId", "vehicleId"]) } : body);
  const technicianId = await technician(db, actor, body.technicianId);
  const odoIn = body.odo === undefined || body.odo === "" || body.odo === null ? null : integer(body.odo, "Odometer reading", 0, 9999999);
  const { number, display } = await nextNumber(db, actor, "job");
  const job: RecordData = {
    id: id("job"),
    branchId: actor.branchId,
    number: display,
    sequence: number,
    estimateId: estimate?.id || null,
    customerId: refs.customerId,
    vehicleId: refs.vehicleId,
    vehicle: refs.vehicle ? fitmentVehicle(refs.vehicle) : null,
    bay: text(body.bay || "", "bay", false, 30),
    technicianId,
    status: "checked-in",
    odoIn,
    complaint: multiline(body.complaint ?? estimate?.notes ?? "", "complaint", false, 1000),
    notes: multiline(body.notes || "", "notes", false, 1000),
    lines: [],
    photos: [],
    holdId: null,
    invoiceId: null,
    history: [historyEntry(actor, "checked-in")],
    createdAt: now(),
    createdBy: actor.id,
    updatedAt: now(),
  };
  job.lines = await documentLines(db, actor, estimate ? estimate.lines : body.lines || [], { job, previous: estimate?.lines });
  await syncJobHold(db, actor, job);
  await withTotals(db, actor, job);
  await putRecord(db, actor.organizationId, "job", job, actor.branchId);
  // Keep the vehicle's odometer current.
  if (refs.vehicle && odoIn !== null && (refs.vehicle.odo ?? 0) <= odoIn) {
    refs.vehicle.odo = odoIn;
    await putRecord(db, actor.organizationId, "customerVehicle", refs.vehicle);
  }
  await audit(db, actor, "job", job.id, estimate ? `Job card from estimate ${estimate.number}` : "Job card opened", { number: job.number });
  return job;
}

function pick(body: any, keys: string[]) {
  return Object.fromEntries(keys.filter((key) => body[key] !== undefined).map((key) => [key, body[key]]));
}

async function technician(db: Database, actor: Actor, value: unknown) {
  if (!value) return null;
  const userId = text(value, "technician", true, 200);
  const user = await getRecord(db, actor.organizationId, "user", userId);
  if (!user || user.active === false) fail("Choose a technician from this shop.");
  return userId;
}

function openJob(job: RecordData) {
  if (job.invoiceId) fail(`This job is already billed (${job.invoiceNumber || "invoice"}).`, 409);
  if (job.status === "cancelled") fail("This job was cancelled. Open a new job card instead.", 409);
  if (job.status === "delivered") fail("This vehicle was already delivered.", 409);
}

/** Checkout hook: bills a job at its quoted prices and closes it. */
const jobBilling: SaleHook = {
  name: "ws-c-job-billing",
  async validateLine(ctx, input, line) {
    if (!ctx.body.jobId) return;
    const job = (ctx.state.wsJob ??= await scoped(ctx.db, ctx.actor, "job", text(ctx.body.jobId, "job", true, 200)));
    if (!input.jobLineId) return;
    const quoted = (job.lines || []).find((entry: Line) => entry.id === input.jobLineId);
    if (!quoted || quoted.productId !== line.productId || quoted.qty !== line.qty)
      fail("The job card changed. Open it again before billing.", 409);
    line.unitPrice = quoted.unitPrice;
    line.subtotal = integer(quoted.unitPrice * line.qty, "Line amount");
    line.kind ??= quoted.kind;
    if (!line.staffId && quoted.staffId) line.staffId = quoted.staffId;
    if (quoted.description) line.description = quoted.description;
    line.jobLineId = quoted.id;
  },
  async beforePersist(ctx) {
    if (!ctx.body.jobId) return;
    const job = await scoped(ctx.db, ctx.actor, "job", text(ctx.body.jobId, "job", true, 200));
    openJob(job);
    const invoice = ctx.invoice!;
    invoice.jobId = job.id;
    invoice.jobNumber = job.number;
    if (!invoice.vehicleId && job.vehicleId) {
      const vehicle = await getRecord(ctx.db, ctx.actor.organizationId, "customerVehicle", job.vehicleId);
      if (vehicle) {
        invoice.vehicleId = vehicle.id;
        invoice.vehicle = { ...fitmentVehicle(vehicle), ...(invoice.vehicle || {}), regNo: vehicle.regNo };
      }
    }
  },
  async afterPersist(ctx) {
    if (!ctx.body.jobId) return;
    const { db, actor } = ctx;
    const invoice = ctx.invoice!;
    const job = (await getRecord(db, actor.organizationId, "job", invoice.jobId!))!;
    job.invoiceId = invoice.id;
    job.invoiceNumber = invoice.number;
    job.billedTotal = invoice.total;
    job.status = "delivered";
    job.deliveredAt = now();
    job.history = [...(job.history || []), historyEntry(actor, "delivered", `Billed on ${invoice.number}`)];
    job.updatedAt = now();
    // The checkout releases the hold it was given; release it here otherwise.
    if (job.holdId && job.holdId !== ctx.hold?.id)
      await db.query("DELETE FROM records WHERE organization_id=$1 AND kind='hold' AND id=$2", [actor.organizationId, job.holdId]);
    job.holdId = null;
    await putRecord(db, actor.organizationId, "job", job, actor.branchId);
    if (job.estimateId) {
      const estimate = await getRecord(db, actor.organizationId, "estimate", job.estimateId);
      if (estimate) {
        estimate.invoiceId = invoice.id;
        await putRecord(db, actor.organizationId, "estimate", estimate, actor.branchId);
      }
    }
  },
};
registerSaleHook(jobBilling);

export function jobRoutes(_app: FastifyInstance, _db: Database, post: Post) {
  // ---------- estimates ----------
  post("estimates", async (tx, actor, body) => {
    allow(actor, WORKSHOP);
    const previous = body.id ? await scoped(tx, actor, "estimate", body.id) : undefined;
    if (previous && ["converted", "rejected"].includes(previous.status))
      fail(previous.status === "converted" ? "This estimate is already a job card. Change the job instead." : "This estimate was rejected. Make a new one.", 409);
    const refs = await partyRefs(tx, actor, body, previous);
    const lines = await documentLines(tx, actor, body.lines ?? previous?.lines ?? [], { previous: previous?.lines });
    if (!lines.length) fail("Add at least one part, labour or kit to the estimate.");
    const validUntil = body.validUntil
      ? day(body.validUntil, "valid-until date")
      : new Date(Date.now() + integer(body.validDays ?? 15, "Valid for (days)", 1, 365) * 86400000).toISOString().slice(0, 10);
    const series = previous ? undefined : await nextNumber(tx, actor, "estimate");
    const estimate: RecordData = {
      ...previous,
      id: previous?.id || id("estimate"),
      branchId: actor.branchId,
      number: previous?.number || series!.display,
      sequence: previous?.sequence || series!.number,
      status: previous?.status === "approved" ? "draft" : previous?.status || "draft",
      customerId: refs.customerId,
      vehicleId: refs.vehicleId,
      vehicle: refs.vehicle ? fitmentVehicle(refs.vehicle) : null,
      lines,
      validUntil,
      notes: multiline(body.notes ?? previous?.notes ?? "", "notes", false, 1000),
      createdAt: previous?.createdAt || now(),
      createdBy: previous?.createdBy || actor.id,
      updatedAt: now(),
    };
    await withTotals(tx, actor, estimate);
    await putRecord(tx, actor.organizationId, "estimate", estimate, actor.branchId);
    await audit(tx, actor, "estimate", estimate.id, previous ? "Estimate changed" : "Estimate made", { number: estimate.number, total: estimate.total });
    return estimate;
  });

  post("estimates/:id/status", async (tx, actor, body, params) => {
    allow(actor, WORKSHOP);
    const estimate = await scoped(tx, actor, "estimate", params.id);
    const status = text(body.status, "status", true, 20);
    if (!["draft", "sent", "approved", "rejected"].includes(status)) fail("Choose sent, approved or rejected.");
    if (estimate.status === "converted") fail("This estimate is already a job card.", 409);
    estimate.status = status;
    estimate[`${status}At`] = now();
    if (status === "approved") estimate.approvedBy = text(body.approvedBy || "", "approved by", false, 100) || "Customer";
    estimate.updatedAt = now();
    await putRecord(tx, actor.organizationId, "estimate", estimate, actor.branchId);
    await audit(tx, actor, "estimate", estimate.id, `Estimate ${status}`);
    return estimate;
  });

  // Approve (if not yet) and open the job card with the estimate's lines.
  post("estimates/:id/job", async (tx, actor, body, params) => {
    allow(actor, WORKSHOP);
    const estimate = await scoped(tx, actor, "estimate", params.id);
    if (estimate.status === "converted") fail(`This estimate is already job card ${estimate.jobNumber || ""}.`.replace(" .", "."), 409);
    if (estimate.status === "rejected") fail("This estimate was rejected. Make a new one.", 409);
    const job = await createJob(tx, actor, body, estimate);
    estimate.status = "converted";
    estimate.approvedAt ??= now();
    estimate.jobId = job.id;
    estimate.jobNumber = job.number;
    estimate.updatedAt = now();
    await putRecord(tx, actor.organizationId, "estimate", estimate, actor.branchId);
    return job;
  });

  // ---------- job cards ----------
  post("jobs", async (tx, actor, body) => {
    allow(actor, WORKSHOP);
    if (!body.id) return createJob(tx, actor, body);
    const job = await scoped(tx, actor, "job", body.id);
    if (job.status === "cancelled") fail("This job was cancelled.", 409);
    const refs = await partyRefs(tx, actor, body, job);
    if (job.invoiceId && (refs.customerId !== job.customerId || refs.vehicleId !== job.vehicleId))
      fail("This job is billed; its customer and vehicle cannot change.", 409);
    Object.assign(job, {
      customerId: refs.customerId,
      vehicleId: refs.vehicleId,
      vehicle: refs.vehicle ? fitmentVehicle(refs.vehicle) : null,
      bay: body.bay === undefined ? job.bay : text(body.bay || "", "bay", false, 30),
      technicianId: body.technicianId === undefined ? job.technicianId : await technician(tx, actor, body.technicianId),
      odoIn: body.odo === undefined ? job.odoIn : body.odo === "" || body.odo === null ? null : integer(body.odo, "Odometer reading", 0, 9999999),
      complaint: body.complaint === undefined ? job.complaint : multiline(body.complaint, "complaint", false, 1000),
      notes: body.notes === undefined ? job.notes : multiline(body.notes, "notes", false, 1000),
      updatedAt: now(),
    });
    if (!job.invoiceId) await syncJobHold(tx, actor, job);
    await putRecord(tx, actor.organizationId, "job", job, actor.branchId);
    return job;
  });

  post("jobs/:id/status", async (tx, actor, body, params) => {
    allow(actor, WORKSHOP);
    const job = await scoped(tx, actor, "job", params.id);
    const status = text(body.status, "status", true, 20);
    if (!(JOB_STATUSES as readonly string[]).includes(status)) fail("Choose a job status.");
    if (job.status === "cancelled") fail("This job was cancelled. Open a new job card instead.", 409);
    if (job.invoiceId && status !== "delivered") fail("This job is billed. Make a return from the invoice if work is undone.", 409);
    if (status === "delivered" && !job.invoiceId && job.lines.length)
      fail("Bill the job before delivering the vehicle.", 409);
    if (status === "cancelled") allow(actor, ["owner", "manager"]);
    job.status = status;
    job.history = [...(job.history || []), historyEntry(actor, status, text(body.note || "", "note", false, 200))];
    if (status === "delivered") job.deliveredAt = now();
    job.updatedAt = now();
    await syncJobHold(tx, actor, job);
    await putRecord(tx, actor.organizationId, "job", job, actor.branchId);
    await audit(tx, actor, "job", job.id, `Job ${status}`, { number: job.number });
    return job;
  });

  // Replace the job's lines (the job card sends the whole list after a scan or edit).
  post("jobs/:id/lines", async (tx, actor, body, params) => {
    allow(actor, WORKSHOP);
    const job = await scoped(tx, actor, "job", params.id);
    openJob(job);
    job.lines = await documentLines(tx, actor, body.lines, { job, previous: job.lines });
    job.updatedAt = now();
    await syncJobHold(tx, actor, job);
    await withTotals(tx, actor, job);
    await putRecord(tx, actor.organizationId, "job", job, actor.branchId);
    return job;
  });

  // Walk-around and defect photos (uploaded first through POST attachments).
  post("jobs/:id/photos", async (tx, actor, body, params) => {
    allow(actor, WORKSHOP);
    const job = await scoped(tx, actor, "job", params.id);
    if (body.remove) {
      const fileId = text(body.remove, "photo", true, 200);
      job.photos = (job.photos || []).filter((photo: any) => photo.id !== fileId);
    } else {
      const tag = body.tag === "defect" ? "defect" : "walkaround";
      const added = await photosFrom(tx, actor, body.photoIds, tag, text(body.note || "", "photo note", false, 200));
      job.photos = [...(job.photos || []), ...added.filter((photo) => !(job.photos || []).some((p: any) => p.id === photo.id))];
      if (job.photos.length > MAX_JOB_PHOTOS) fail(`A job can have ${MAX_JOB_PHOTOS} photos at most.`);
    }
    job.updatedAt = now();
    await putRecord(tx, actor.organizationId, "job", job, actor.branchId);
    return job;
  });

  // UI polish: an advance taken against this job. It is an ordinary customer
  // advance (routes/customers.ts) that also records the job, so the job card can
  // show it; billing the job then uses it through the "Advance" tender.
  post("jobs/:id/advances", async (tx, actor, body, params) => {
    allow(actor, SELLERS);
    const job = await scoped(tx, actor, "job", params.id);
    openJob(job);
    if (!job.customerId) fail("Choose the customer on the job before taking an advance.");
    const customer = await scoped(tx, actor, "customer", job.customerId);
    const record = await advanceMovement(tx, actor, body, customer.id, false);
    const notes = String(body.notes || "").trim();
    Object.assign(record, { jobId: job.id, jobNumber: job.number, notes: `Advance · Job ${job.number}${notes ? ` · ${notes}` : ""}` });
    await putRecord(tx, actor.organizationId, "partyPayment", record, actor.branchId);
    return record;
  });

  // One-click GST invoice from the job card, through the normal checkout.
  // A customer advance is used by sending an "Advance" tender (hooks/advance.ts).
  post("jobs/:id/invoice", async (tx, actor, body, params) => {
    allow(actor, SELLERS);
    const job = await scoped(tx, actor, "job", params.id);
    openJob(job);
    if (!job.lines.length) fail("Add parts or labour to the job before billing.");
    for (const line of job.lines as Line[]) {
      if (line.kind !== "part") continue;
      const product = await getRecord(tx, actor.organizationId, "product", line.productId);
      if (product?.serialTracked && (line.serials?.length || 0) !== line.qty)
        fail(`Scan the serial numbers for ${line.sku} onto the job before billing.`);
    }
    const hold = job.holdId ? await getRecord(tx, actor.organizationId, "hold", job.holdId) : undefined;
    return finalizeSale(tx, actor, {
      [JOB_INVOICE]: true,
      transactionId: body.transactionId || randomUUID(),
      shiftId: body.shiftId,
      tenders: body.tenders,
      placeOfSupply: body.placeOfSupply,
      expectedTotal: body.expectedTotal,
      customerId: job.customerId || undefined,
      vehicleId: job.vehicleId || undefined,
      jobId: job.id,
      holdId: hold ? hold.id : undefined,
      lines: job.lines.map((line: Line) => ({
        productId: line.productId,
        qty: line.qty,
        ...(line.binId ? { binId: line.binId } : {}),
        ...(line.serials?.length ? { serials: line.serials } : {}),
        staffId: line.staffId || job.technicianId || undefined,
        jobLineId: line.id,
      })),
    });
  });
}
