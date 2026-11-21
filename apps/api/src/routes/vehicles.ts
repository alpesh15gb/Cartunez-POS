// WS-C (workshop): the customer vehicle registry.
//
// A `customerVehicle` record is one car that comes to the shop, keyed by its
// registration number (normalised: upper case, letters and digits only, unique
// per organisation). It links to a customer and carries what the fitment check
// needs (make, model, year, fuel, variant). Selecting a vehicle at the counter
// sets the cart's fitment vehicle and `invoice.vehicleId` (hook below).
import type { FastifyInstance } from "fastify";
import type { Database, RecordData } from "../db.js";
import type { Post } from "./types.js";
import { getRecord, putRecord, records } from "../db.js";
import { type Actor, allow, audit, fail, id, integer, multiline, normalize, now, scoped, text } from "../domain.js";
import { registerSaleHook } from "../sale-pipeline.js";
import type { SaleHook } from "../sale-types.js";

const SELLERS = ["owner", "manager", "cashier"];
const ANYONE = ["owner", "manager", "cashier", "inventory"];
const FUELS = ["", "Petrol", "Diesel", "CNG", "LPG", "Electric", "Hybrid"];
const MAX_VEHICLE_PHOTOS = 12;

/** MH 12 AB 1234 / mh-12-ab-1234 -> MH12AB1234 */
export const normalizeRegNo = (value: unknown) => normalize(value);

/** The shape the fitment check (domain.ts fitment / core/billing.dart) reads. */
export function fitmentVehicle(vehicle: RecordData) {
  return {
    id: vehicle.id,
    regNo: vehicle.regNo,
    make: vehicle.make,
    model: vehicle.model,
    year: vehicle.year,
    ...(vehicle.fuel ? { fuel: vehicle.fuel } : {}),
    ...(vehicle.engine ? { engine: vehicle.engine } : {}),
    ...(vehicle.variant ? { trim: vehicle.variant } : {}),
  };
}

export async function findVehicleByRegNo(db: Database, org: string, regNo: string) {
  const key = normalizeRegNo(regNo);
  if (!key) return undefined;
  const { rows } = await db.query(
    "SELECT data FROM records WHERE organization_id=$1 AND kind='customerVehicle' AND data->>'regKey'=$2 LIMIT 1",
    [org, key],
  );
  return rows[0]?.data as RecordData | undefined;
}

async function photosFrom(db: Database, actor: Actor, value: unknown) {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) fail("Photos must be a list.");
  if (value.length > MAX_VEHICLE_PHOTOS) fail(`Attach ${MAX_VEHICLE_PHOTOS} photos at most.`);
  const photos = [];
  for (const entry of value) {
    const fileId = typeof entry === "string" ? entry : entry?.id;
    const file = await getRecord(db, actor.organizationId, "attachment", String(fileId));
    if (!file) fail("A photo was not uploaded. Add it again.");
    photos.push({ id: file.id, contentType: file.contentType, name: file.name || "" });
  }
  return photos;
}

/** Validates and saves a vehicle (create when no id). */
export async function saveVehicle(db: Database, actor: Actor, body: any) {
  allow(actor, ANYONE);
  const previous = body.id ? await scoped(db, actor, "customerVehicle", body.id) : undefined;
  const regNo = text(body.regNo ?? previous?.regNo ?? "", "registration number", true, 20).toUpperCase();
  const regKey = normalizeRegNo(regNo);
  if (regKey.length < 4) fail("Enter the full registration number, for example MH 12 AB 1234.");
  const clash = await findVehicleByRegNo(db, actor.organizationId, regKey);
  if (clash && clash.id !== previous?.id)
    fail(`${clash.regNo} is already registered${clash.make ? ` (${clash.make} ${clash.model})` : ""}. Open that vehicle instead.`, 409);
  const field = (key: string, label: string, max = 60) => text(body[key] ?? previous?.[key] ?? "", label, false, max);
  const customerId = body.customerId === undefined ? previous?.customerId || null : body.customerId || null;
  if (customerId) await scoped(db, actor, "customer", customerId);
  const yearValue = body.year ?? previous?.year ?? "";
  const year = yearValue === "" || yearValue === null ? null : integer(yearValue, "Year", 1950, new Date().getUTCFullYear() + 1);
  const odoValue = body.odo ?? previous?.odo ?? "";
  const odo = odoValue === "" || odoValue === null ? null : integer(odoValue, "Odometer reading", 0, 9999999);
  const fuel = field("fuel", "fuel", 20);
  if (!FUELS.includes(fuel)) fail("Choose petrol, diesel, CNG, LPG, electric or hybrid.");
  const vehicle = {
    ...previous,
    id: previous?.id || id("cveh"),
    regNo,
    regKey,
    customerId,
    make: field("make", "make"),
    model: field("model", "model"),
    variant: field("variant", "variant"),
    engine: field("engine", "engine", 30),
    year,
    fuel,
    odo,
    vin: field("vin", "VIN / chassis number", 30).toUpperCase(),
    notes: multiline(body.notes ?? previous?.notes ?? "", "notes", false, 1000),
    photos: (await photosFrom(db, actor, body.photoIds ?? body.photos)) ?? previous?.photos ?? [],
    createdAt: previous?.createdAt || now(),
    updatedAt: now(),
  };
  await putRecord(db, actor.organizationId, "customerVehicle", vehicle);
  await audit(db, actor, "vehicle", vehicle.id, previous ? "Vehicle updated" : "Vehicle registered", { regNo });
  return vehicle;
}

/** Search by registration number (any spacing), VIN, make/model, or owner name/phone. */
export async function searchVehicles(db: Database, actor: Actor, query: string, limit = 30) {
  const key = normalize(query);
  const vehicles = await records(db, actor.organizationId, "customerVehicle");
  const customers = new Map((await records(db, actor.organizationId, "customer")).map((c) => [c.id, c]));
  const scored = vehicles
    .map((vehicle) => {
      const customer = customers.get(vehicle.customerId);
      let score = 0;
      if (!key) score = 1;
      else if (vehicle.regKey === key) score = 100;
      else if (vehicle.regKey.endsWith(key)) score = 60; // the last digits people remember
      else if (vehicle.regKey.includes(key)) score = 50;
      else if (vehicle.vin && normalize(vehicle.vin).includes(key)) score = 40;
      else if (normalize(`${customer?.phone || ""}`).includes(key)) score = 30;
      else if (normalize(`${vehicle.make} ${vehicle.model} ${customer?.name || ""}`).includes(key)) score = 20;
      return { vehicle, customer, score };
    })
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score || String(b.vehicle.updatedAt).localeCompare(String(a.vehicle.updatedAt)));
  return scored.slice(0, limit).map(({ vehicle, customer }) => ({
    ...vehicle,
    customerName: customer?.name || "",
    customerPhone: customer?.phone || "",
  }));
}

/** Puts the customer vehicle on the invoice when the sale names one. */
const vehicleOnInvoice: SaleHook = {
  name: "ws-c-vehicle-on-invoice",
  async beforePersist(ctx) {
    // The counter puts the registry id on its fitment vehicle; the job card sends vehicleId.
    const vehicleId = ctx.body.vehicleId || ctx.body.vehicle?.customerVehicleId;
    if (!vehicleId) return;
    const vehicle = await scoped(ctx.db, ctx.actor, "customerVehicle", text(vehicleId, "vehicle", true, 200));
    ctx.invoice!.vehicleId = vehicle.id;
    // Shown on the receipt; the fitment vehicle the counter sent is kept if there was one.
    ctx.invoice!.vehicle = { ...fitmentVehicle(vehicle), ...(ctx.invoice!.vehicle || {}), regNo: vehicle.regNo };
  },
  async afterPersist(ctx) {
    const invoice = ctx.invoice!;
    const vehicleId = invoice.vehicleId;
    if (!vehicleId) return;
    const vehicle = await getRecord(ctx.db, ctx.actor.organizationId, "customerVehicle", vehicleId);
    if (!vehicle) return;
    vehicle.lastInvoiceId = invoice.id;
    vehicle.lastVisitAt = invoice.createdAt;
    // A walk-in vehicle sold to a named customer is linked to them.
    if (!vehicle.customerId && invoice.customerId) vehicle.customerId = invoice.customerId;
    await putRecord(ctx.db, ctx.actor.organizationId, "customerVehicle", vehicle);
  },
};
registerSaleHook(vehicleOnInvoice);

export function vehicleRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("customer-vehicles", async (tx, actor, body) => saveVehicle(tx, actor, body));

  app.get("/api/v1/customer-vehicles", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ANYONE);
    const q = typeof request.query?.q === "string" ? request.query.q.slice(0, 60) : "";
    return { rows: await searchVehicles(db, actor, q) };
  });

  // Exact registration lookup, e.g. from the counter or a scanned number plate.
  app.get("/api/v1/customer-vehicles/by-reg/:regNo", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ANYONE);
    const vehicle = await findVehicleByRegNo(db, actor.organizationId, String(request.params.regNo));
    if (!vehicle) fail("No vehicle with that registration number yet. Add it to the registry.", 404);
    return vehicle;
  });

  // One vehicle with its history: jobs and invoices in this branch.
  app.get("/api/v1/customer-vehicles/:id", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ANYONE);
    const vehicle = await getRecord(db, actor.organizationId, "customerVehicle", String(request.params.id));
    if (!vehicle) fail("Vehicle not found.", 404);
    const byVehicle = async (kind: string) =>
      (await db.query(
        "SELECT data FROM records WHERE organization_id=$1 AND branch_id=$2 AND kind=$3 AND data->>'vehicleId'=$4 ORDER BY created_at DESC LIMIT 50",
        [actor.organizationId, actor.branchId, kind, vehicle.id],
      )).rows.map((row) => row.data);
    const invoices = (await byVehicle("invoice"))
      .filter((invoice) => SELLERS.includes(actor.role) && (actor.role !== "cashier" || invoice.cashierId === actor.id))
      .map(({ id, number, createdAt, total, lines }) => ({ id, number, createdAt, total, lines: lines.length }));
    const jobs = (await byVehicle("job")).map(({ id, number, status, createdAt, invoiceId, odoIn }) => ({ id, number, status, createdAt, invoiceId, odoIn }));
    const estimates = (await byVehicle("estimate")).map(({ id, number, status, createdAt, total }) => ({ id, number, status, createdAt, total }));
    const customer = vehicle.customerId ? await getRecord(db, actor.organizationId, "customer", vehicle.customerId) : null;
    return { vehicle, customer, invoices, jobs, estimates };
  });
}
