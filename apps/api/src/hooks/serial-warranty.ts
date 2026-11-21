// WS-C (workshop): serial / IMEI warranty tracking.
//
// The counter already insists on one scanned serial per unit of a
// serial-tracked part, and the built-in stock-and-serials hook marks each
// serial sold. This hook then records who bought it and until when it is under
// warranty: serial.invoiceId, invoiceNumber, customerId, vehicleId, soldAt and
// warrantyUntil = sale date + product.warrantyMonths (a calendar date in the
// shop's business time zone, inclusive). When a return, exchange or void puts
// the serial back on the shelf (returns.ts), these sale facts move to
// `serial.history` and are cleared, so the lookup shows it in stock ("not
// sold"); a serial returned as damaged or for a supplier warranty keeps them
// (only invoiceId is cleared).
import type { FastifyInstance } from "fastify";
import type { Database, RecordData } from "../db.js";
import { getRecord, putRecord } from "../db.js";
import { type Actor, allow, fail, now } from "../domain.js";
import { registerSaleHook } from "../sale-pipeline.js";
import type { SaleHook } from "../sale-types.js";

/** India business time for INR shops (as the reports use), UTC otherwise. */
export function businessDay(instant: string, currency = "INR") {
  const time = new Date(instant).getTime() + (currency === "INR" ? 330 * 60000 : 0);
  return new Date(time).toISOString().slice(0, 10);
}

/** 2026-01-31 + 1 month = 2026-02-28 (end of month is kept within the month). */
export function addMonths(date: string, months: number) {
  const [year, month, day] = date.split("-").map(Number);
  const last = new Date(Date.UTC(year, month - 1 + months + 1, 0)).getUTCDate();
  return new Date(Date.UTC(year, month - 1 + months, Math.min(day, last))).toISOString().slice(0, 10);
}

export function warrantyUntil(soldAt: string, months: number, currency = "INR") {
  return months > 0 ? addMonths(businessDay(soldAt, currency), months) : null;
}

export function warrantyStatus(serial: RecordData, today = businessDay(now())) {
  if (!serial.soldAt) return "not sold";
  if (!serial.warrantyUntil) return "no warranty";
  return today <= serial.warrantyUntil ? "in warranty" : "expired";
}

const serialWarranty: SaleHook = {
  name: "ws-c-serial-warranty",
  async afterPersist(ctx) {
    const invoice = ctx.invoice!;
    const soldAt = String(invoice.createdAt || now());
    for (const line of ctx.lines) {
      if (!line.serials?.length) continue;
      const product = await getRecord(ctx.db, ctx.actor.organizationId, "product", line.productId);
      const months = Number(product?.warrantyMonths || 0);
      for (const serial of line.serials) {
        const key = line.productId + ":" + serial;
        const record = await getRecord(ctx.db, ctx.actor.organizationId, "serial", key);
        if (!record) continue;
        Object.assign(record, {
          invoiceId: invoice.id,
          invoiceNumber: invoice.number,
          customerId: invoice.customerId || null,
          vehicleId: invoice.vehicleId || null,
          soldAt,
          warrantyMonths: months,
          warrantyUntil: warrantyUntil(soldAt, months, String(invoice.currency || "INR")),
        });
        await putRecord(ctx.db, ctx.actor.organizationId, "serial", record, record.branchId || ctx.actor.branchId);
      }
    }
  },
};
registerSaleHook(serialWarranty);

/** Everything known about a serial / IMEI, for the warranty lookup screen. */
export async function lookupSerial(db: Database, actor: Actor, code: string) {
  const serial = code.trim();
  if (!serial || serial.length > 100) fail("Scan or type a serial number.");
  const { rows } = await db.query(
    "SELECT data FROM records WHERE organization_id=$1 AND kind='serial' AND upper(data->>'serial')=upper($2) ORDER BY created_at LIMIT 20",
    [actor.organizationId, serial],
  );
  const results = [];
  for (const { data } of rows) {
    const product = await getRecord(db, actor.organizationId, "product", data.productId);
    const invoiceId = data.invoiceId || null;
    const invoice = invoiceId ? await getRecord(db, actor.organizationId, "invoice", invoiceId) : undefined;
    const ownInvoice = invoice && (actor.role !== "cashier" || invoice.cashierId === actor.id);
    const customer = data.customerId ? await getRecord(db, actor.organizationId, "customer", data.customerId) : undefined;
    const vehicle = data.vehicleId ? await getRecord(db, actor.organizationId, "customerVehicle", data.vehicleId) : undefined;
    results.push({
      serial: data.serial,
      status: data.status,
      branchId: data.branchId,
      binId: data.binId,
      product: product ? { id: product.id, sku: product.sku, name: product.name, warrantyMonths: product.warrantyMonths || 0 } : null,
      invoice: invoice
        ? { id: invoice.id, number: invoice.number, createdAt: invoice.createdAt, total: ownInvoice ? invoice.total : undefined }
        : data.invoiceNumber ? { id: null, number: data.invoiceNumber } : null,
      customer: customer ? { id: customer.id, name: customer.name, phone: customer.phone || "" } : null,
      vehicle: vehicle ? { id: vehicle.id, regNo: vehicle.regNo, make: vehicle.make, model: vehicle.model } : null,
      soldAt: data.soldAt || null,
      warrantyUntil: data.warrantyUntil || null,
      warranty: warrantyStatus(data),
      // Earlier sales that came back (returned, exchanged or voided).
      history: Array.isArray(data.history) ? data.history : [],
      // A return can be taken while the serial is still on its invoice in this branch.
      canReturn: data.status === "sold" && !!invoice && invoice.branchId === actor.branchId,
    });
  }
  return results;
}

export function serialWarrantyRoutes(app: FastifyInstance, db: Database) {
  app.get("/api/v1/serials/lookup", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager", "cashier", "inventory"]);
    const code = typeof request.query?.code === "string" ? request.query.code : "";
    return { rows: await lookupSerial(db, actor, code) };
  });
}
