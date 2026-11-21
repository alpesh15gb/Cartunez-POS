// WS-B: Returns and GST credit notes.
//
// A return is always linked to the original invoice. Each returned line has a
// stock disposition:
//   restock - back into a sellable bin
//   damaged - into a damaged-stock bin (not sellable)
//   rma     - into a warranty bin and a warranty claim is opened with the supplier
// The credit note (record kind "return") is settled one of three ways:
//   Cash / Card / UPI - refunded through the open shift
//   Credit            - store credit on the customer's account (lowers their balance)
//   Exchange          - set against a new invoice at the counter (hooks/exchange.ts);
//                       any excess is refunded by `refundType` and is `refundTotal`.
// `refundTotal` (when present) is the part of the credit note paid back by
// `refundType`; readers fall back to `total` for returns written before it existed.
import type { FastifyInstance } from "fastify";
import type { Database, RecordData } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { type Actor, adjust, allow, approved, audit, fail, id, integer, normalize, now, roundRatio, scoped, text } from "./domain.js";
import { documentNumber, invoiceProfile, taxTotals } from "./settings.js";

export const REFUND_TYPES = ["Cash", "Card", "UPI", "Credit"];
export const DISPOSITIONS = ["restock", "damaged", "rma"] as const;
export type Disposition = (typeof DISPOSITIONS)[number];

/** Bin kind each disposition puts stock into. */
const binKind: Record<Disposition, string> = { restock: "sellable", damaged: "damaged", rma: "warranty" };
/** Old whole-return `condition` values map onto dispositions. */
const fromCondition: Record<string, Disposition> = { sellable: "restock", damaged: "damaged", warranty: "rma" };

export interface ReturnOptions {
  /** Set by the exchange hook: the new invoice's total the credit is set against. */
  exchangeTotal?: number;
}

/** The amount of a credit note paid back by its refund method. */
export const refundAmount = (ret: RecordData) => Number(ret.refundTotal ?? ret.total ?? 0);

/** The text a receipt's barcode/QR carries so the return desk can scan it (the invoice number). */
export const invoiceCode = (invoice: RecordData) => String(invoice.number || "");

/** A bin of the given kind in this branch; one is created under "Returns" when the shop has none. */
async function binFor(db: Database, actor: Actor, kind: string, preferred?: string | null) {
  const bins = (await records(db, actor.organizationId, "location", actor.branchId)).filter((b) => b.kind === kind);
  const match = bins.find((b) => b.id === preferred) || bins[0];
  if (match) return match;
  const bin = {
    id: id("bin"),
    branchId: actor.branchId,
    area: "Returns",
    rack: kind === "damaged" ? "DMG" : "RMA",
    shelf: "1",
    bin: "01",
    kind,
  };
  await putRecord(db, actor.organizationId, "location", bin, actor.branchId);
  await audit(db, actor, "location", bin.id, `Created a ${kind} bin for returns`, bin);
  return bin;
}

/** What is still returnable on each line of an invoice. */
export async function returnableLines(db: Database, actor: Actor, invoice: RecordData) {
  const previous = (await records(db, actor.organizationId, "return", actor.branchId)).filter(
    (item) => item.invoiceId === invoice.id,
  );
  const voided = previous.some((item) => item.voided);
  return {
    voided,
    lines: (invoice.lines || []).map((line: any) => {
      const earlier = previous.flatMap((item) => item.lines).filter((item: any) => item.lineId === line.id);
      const returnedQty = earlier.reduce((sum: number, item: any) => sum + item.quantity, 0);
      const returnedSerials = new Set(earlier.flatMap((item: any) => item.serials || []));
      return {
        lineId: line.id,
        productId: line.productId,
        sku: line.sku,
        name: line.name,
        type: line.type,
        qty: line.qty,
        binId: line.binId,
        supplierId: line.supplierId || "",
        returnedQty,
        returnableQty: voided ? 0 : line.qty - returnedQty,
        // Credit for q more units = max(0, round(refundable * (returnedQty + q) / qty) - refundedSoFar).
        refundable: line.total - (line.coreCharge || 0) * line.qty,
        refundedSoFar: earlier.reduce((sum: number, item: any) => sum + item.total, 0),
        serials: (line.serials || []).filter((serial: string) => !returnedSerials.has(serial)),
      };
    }),
  };
}

export async function returnInvoice(
  db: Database,
  actor: Actor,
  invoiceId: string,
  body: any,
  voided = false,
  options: ReturnOptions = {},
) {
  allow(actor, ["owner", "manager", "cashier"]);
  await approved(db, actor, "return", body.approvalId, body.transactionId);
  const invoice = await scoped(db, actor, "invoice", invoiceId);
  const shift = (await records(db, actor.organizationId, "shift", actor.branchId)).find(
    (item) => item.userId === actor.id && !item.closedAt,
  );
  if (!shift) fail("Open your shift before recording a refund.", 409);
  const previous = (await records(db, actor.organizationId, "return", actor.branchId)).filter(
    (item) => item.invoiceId === invoiceId,
  );
  if (previous.some((item) => item.voided)) fail(`Invoice ${invoice.number} was voided, so nothing on it can be returned.`, 409);
  text(body.reason, "return reason");
  if (body.condition !== undefined && !fromCondition[body.condition]) fail("Choose return condition.");
  if (!Array.isArray(body.lines) || !body.lines.length) fail("Select return lines.");
  const lines: any[] = [];
  const used = new Set<string>();
  const claims: { line: any; supplierId: string }[] = [];
  for (const input of body.lines) {
    const original = invoice.lines.find((line: any) =>
      input.lineId ? line.id === input.lineId : line.productId === input.productId,
    );
    if (!original) fail("Select an original invoice line.");
    if (used.has(original.id)) fail("Combine duplicate return lines.");
    used.add(original.id);
    const disposition: Disposition = input.disposition ?? fromCondition[body.condition] ?? fail(`Choose what happens to ${original.name}: back to shelf, damaged or supplier warranty.`);
    if (!DISPOSITIONS.includes(disposition)) fail(`Choose what happens to ${original.name}: back to shelf, damaged or supplier warranty.`);
    const returned = previous
      .flatMap((item) => item.lines)
      .filter((item) => item.lineId === original.id)
      .reduce((sum, line) => sum + line.quantity, 0);
    if (original.qty - returned < 1) fail(`${original.name} on invoice ${invoice.number} has already been returned.`);
    const quantity = integer(input.quantity ?? input.qty, `Return quantity for ${original.name}`, 1, original.qty - returned);
    const kind = binKind[disposition];
    let bin: RecordData | null = null;
    if (original.type !== "service") {
      if (input.binId) {
        bin = await scoped(db, actor, "location", input.binId);
        if (bin.kind !== kind) fail("Return destination must match the condition.");
      } else bin = await binFor(db, actor, kind, kind === "sellable" ? original.binId : null);
    }
    // Integration (WS-B x WS-C): a returned kit puts its stocked components back,
    // in proportion to the kits returned, into the chosen bin.
    let components: any[] | undefined;
    if (original.kind === "kit" && Array.isArray(original.components) && disposition !== "rma") {
      const share = (qty: number) =>
        roundRatio(qty, returned + quantity, original.qty) - roundRatio(qty, returned, original.qty);
      const byProduct = new Map<string, any>();
      for (const component of original.components) {
        if (!component.binId || component.type === "service") continue;
        const entry = byProduct.get(component.productId) || { ...component, qty: 0, fromBinId: component.binId };
        entry.qty += Number(component.qty) || 0;
        byProduct.set(component.productId, entry);
      }
      if (byProduct.size) {
        if (input.binId) {
          bin = await scoped(db, actor, "location", input.binId);
          if (bin.kind !== kind) fail("Return destination must match the condition.");
        } else bin = await binFor(db, actor, kind, kind === "sellable" ? [...byProduct.values()][0].fromBinId : null);
        components = [...byProduct.values()]
          .map((entry) => ({ productId: entry.productId, sku: entry.sku, name: entry.name, qty: share(entry.qty), binId: bin!.id }))
          .filter((entry) => entry.qty > 0);
      }
    }
    const product = await scoped(db, actor, "product", original.productId);
    const serials = input.serials || [];
    if (original.serials?.length) {
      if (!Array.isArray(serials) || serials.length !== quantity || new Set(serials).size !== quantity)
        fail("Return one serial number for each unit.");
      for (const serial of serials) {
        const item = await scoped(db, actor, "serial", product.id + ":" + serial);
        if (!original.serials.includes(serial) || item.status !== "sold" || item.invoiceId !== invoiceId)
          fail("Serial was not sold on this invoice or has already been returned.");
        await putRecord(
          db,
          actor.organizationId,
          "serial",
          { ...item, status: kind === "sellable" ? "available" : kind, binId: bin!.id, invoiceId: null },
          actor.branchId,
        );
      }
    }
    const proportion = (value: number) =>
      roundRatio(value, returned + quantity, original.qty) - roundRatio(value, returned, original.qty);
    const subtotal = proportion(original.subtotal),
      discount = proportion(original.discount),
      tax = proportion(original.tax);
    // Allocate component refunds from cumulative tax, preserving both each credit's tax
    // total and each original component across any series of partial returns.
    let componentCumulative = 0,
      componentAllocatedBefore = 0,
      componentAllocatedAfter = 0;
    const taxBefore = roundRatio(original.tax, returned, original.qty);
    const taxAfter = roundRatio(original.tax, returned + quantity, original.qty);
    const taxComponents = (original.taxComponents || []).map((component: any) => {
      componentCumulative += component.amount;
      const before = original.tax ? roundRatio(taxBefore, componentCumulative, original.tax) : 0;
      const after = original.tax ? roundRatio(taxAfter, componentCumulative, original.tax) : 0;
      const amount = after - componentAllocatedAfter - before + componentAllocatedBefore;
      componentAllocatedBefore = before;
      componentAllocatedAfter = after;
      return { ...component, amount };
    });
    // Allocate the refundable amount cumulatively so rounding components separately
    // cannot produce a negative credit or pay the last unit twice.
    const priorRefund = previous
      .flatMap((item) => item.lines)
      .filter((line) => line.lineId === original.id)
      .reduce((sum, line) => sum + line.total, 0);
    const refundable = original.total - (original.coreCharge || 0) * original.qty;
    const total = Math.max(0, roundRatio(refundable, returned + quantity, original.qty) - priorRefund);
    const rounding = total - (subtotal - discount + (invoice.taxMode === "inclusive" ? 0 : tax));
    const line = {
      lineId: original.id,
      productId: original.productId,
      sku: original.sku,
      name: original.name,
      hsnSac: original.hsnSac || "",
      unit: original.unit,
      taxRate: original.taxRate,
      quantity,
      binId: bin?.id || null,
      type: original.type,
      disposition,
      condition: kind,
      serials,
      subtotal,
      discount,
      tax,
      taxComponents,
      rounding,
      taxMode: invoice.taxMode || "exclusive",
      total,
      cost: original.cost * quantity,
      ...(components ? { kind: "kit", components } : {}),
    };
    lines.push(line);
    if (disposition === "rma") {
      const supplierId = String(input.supplierId || original.supplierId || product.supplierId || "");
      if (!supplierId) fail(`Choose the supplier to claim the warranty on ${original.name} from.`);
      await scoped(db, actor, "supplier", supplierId);
      claims.push({ line, supplierId });
    }
  }
  const total = lines.reduce((sum, line) => sum + line.total, 0);
  const settings = (await getRecord(db, actor.organizationId, "settings", "settings"))!;
  const creditNumber = settings.nextCreditNote || 1;
  settings.nextCreditNote = creditNumber + 1;
  await putRecord(db, actor.organizationId, "settings", settings);
  if (!body.refundType && (invoice.tenders || []).some((t: any) => t.type === "Credit")) body.refundType = "Credit";
  const refundType = body.refundType || "Cash";
  if (!REFUND_TYPES.includes(refundType)) fail("Choose a supported refund method.");
  const exchange = options.exchangeTotal !== undefined;
  const applied = exchange ? Math.min(total, options.exchangeTotal!) : 0;
  const refundTotal = total - applied;
  if (refundType === "Credit" && refundTotal > 0 && !invoice.customerId)
    fail("Only a sale to a named customer can be refunded to their account.");
  const dispositions = [...new Set(lines.map((line) => line.condition))];
  const receipt: RecordData = {
    ...invoiceProfile(invoice, invoice.branch || { id: invoice.branchId, name: "" }),
    customer: invoice.customer || null,
    customerId: invoice.customerId || null,
    placeOfSupply: invoice.placeOfSupply || "",
    id: id("return"),
    number: documentNumber(
      `${settings.creditNotePrefix || "CR"}-${actor.branchId.toUpperCase()}-${creditNumber}`,
      invoice.taxScheme || "general",
    ),
    invoiceNumber: invoice.number,
    invoiceDate: invoice.createdAt,
    branchId: actor.branchId,
    invoiceId,
    transactionId: body.transactionId,
    userId: actor.id,
    shiftId: shift.id,
    createdAt: now(),
    reason: body.reason,
    // One condition for the whole return, or "mixed" when lines went to different bins.
    condition: dispositions.length === 1 ? dispositions[0] : "mixed",
    // An exchange with nothing left to pay back is settled entirely against the new invoice.
    refundType: exchange && refundTotal === 0 ? "Exchange" : refundType,
    total,
    tax: lines.reduce((sum, line) => sum + line.tax, 0),
    taxComponents: taxTotals(lines),
    lines,
    voided,
  };
  if (exchange) Object.assign(receipt, { exchangeApplied: applied, refundTotal });
  for (const line of lines) {
    if (line.type !== "service")
      await adjust(db, actor, line.productId, line.binId, line.quantity, voided ? "Invoice void" : "Sales return", receipt.id);
    for (const component of (line as any).components || [])
      await adjust(db, actor, component.productId, component.binId, component.qty, voided ? "Invoice void" : "Sales return", receipt.id);
  }
  const claimIds: string[] = [];
  for (const { line, supplierId } of claims) {
    const claim = {
      id: id("warranty"),
      branchId: actor.branchId,
      returnId: receipt.id,
      lineId: line.lineId,
      productId: line.productId,
      quantity: line.quantity,
      serials: line.serials,
      supplierId,
      invoiceId,
      reason: `${body.reason} (${line.name}, credit note ${receipt.number})`.slice(0, 200),
      status: "open",
      createdAt: now(),
      updatedAt: now(),
    };
    await putRecord(db, actor.organizationId, "warranty", claim, actor.branchId);
    await audit(db, actor, "warranty", claim.id, claim.reason, { status: "open", returnId: receipt.id });
    claimIds.push(claim.id);
  }
  if (claimIds.length) receipt.warrantyClaimIds = claimIds;
  await putRecord(db, actor.organizationId, "return", receipt, actor.branchId);
  await audit(db, actor, voided ? "invoice-void" : "return", invoiceId, body.reason, { returnId: receipt.id, total });
  return receipt;
}

/** Last ten digits of a phone number, for matching "+91 98..." against "98...". */
const phoneKey = (value: unknown) => String(value ?? "").replace(/\D/g, "").slice(-10);

/**
 * Finds invoices to return against by invoice number (or the receipt's scanned
 * code), customer phone number or a sold serial number. Newest first.
 */
export async function findInvoicesForReturn(db: Database, actor: Actor, query: string) {
  const q = String(query || "").trim();
  if (q.length < 2) fail("Enter at least two characters: invoice number, phone or serial number.");
  const key = normalize(q);
  const phone = phoneKey(q);
  const customers = phone.length >= 6
    ? (await records(db, actor.organizationId, "customer")).filter((c) => phoneKey(c.phone).endsWith(phone)).map((c) => c.id)
    : [];
  const invoices = (await records(db, actor.organizationId, "invoice", actor.branchId))
    .filter((invoice) => {
      const number = normalize(invoice.number);
      if (number === key || String(invoice.invoiceNumber) === q || (key.length >= 3 && number.endsWith(key))) return true;
      if (customers.includes(invoice.customerId)) return true;
      return (invoice.lines || []).some((line: any) => (line.serials || []).some((s: string) => normalize(s) === key));
    })
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .slice(0, 20);
  const results = [];
  for (const invoice of invoices) {
    const { voided, lines } = await returnableLines(db, actor, invoice);
    results.push({
      id: invoice.id,
      number: invoice.number,
      createdAt: invoice.createdAt,
      customerId: invoice.customerId || null,
      customer: invoice.customer ? { id: invoice.customer.id, name: invoice.customer.name, phone: invoice.customer.phone } : null,
      total: invoice.total,
      tenders: invoice.tenders,
      voided,
      lines,
    });
  }
  return results;
}

export function returnRoutes(app: FastifyInstance, db: Database) {
  app.get("/api/v1/returns/lookup", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager", "cashier"]);
    const query = String(request.query?.q ?? "");
    const results = await db.readSnapshot((tx) => findInvoicesForReturn(tx, actor, query));
    if (actor.role !== "cashier") return results;
    // Security: a cashier gets exact matches only (the full invoice number, the
    // full 10-digit phone or an exact serial), bills of the last 180 days in
    // this branch, at most 10, and only the tender types (no references).
    const key = normalize(query.trim());
    const phone = phoneKey(query);
    const exactPhone = phone.length === 10 && query.replace(/[\s+-]/g, "").replace(/^91/, "").length === 10;
    const since = Date.now() - 180 * 86400000;
    const customerIds = exactPhone
      ? new Set((await records(db, actor.organizationId, "customer")).filter((c) => phoneKey(c.phone) === phone).map((c) => c.id))
      : new Set<string>();
    return results
      .filter((invoice: any) => Date.parse(invoice.createdAt) >= since)
      .filter((invoice: any) =>
        normalize(invoice.number) === key ||
        (exactPhone && (customerIds.has(invoice.customerId) || phoneKey(invoice.customer?.phone) === phone)) ||
        invoice.lines.some((line: any) => (line.serials || []).some((s: string) => normalize(s) === key)))
      .slice(0, 10)
      .map((invoice: any) => ({
        ...invoice,
        customer: invoice.customer ? { id: invoice.customer.id, name: invoice.customer.name } : null,
        tenders: (invoice.tenders || []).map((t: any) => ({ type: t.type, amount: t.amount })),
      }));
  });
}
