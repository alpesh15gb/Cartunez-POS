// WS-E: online order fulfilment. The POS invoices website orders:
//   Magento order arrives (stock reserved, magento-orders.ts)
//   → pick list (per order, or a batch of orders), picked by scanning
//   → "Invoice & pack": a GST invoice through the normal checkout pipeline on
//     the branch's online till (hooks/online-channel.ts); the reservation turns
//     into the sale's stock movement. Lines carry Magento's row totals, so the
//     POS total equals the website's grand total.
//   → courier and tracking number → the shipment is sent to Magento by a worker
//     (never inside a database transaction), retried when Magento fails. The
//     worker claims the job first and reads the Magento order before and after
//     shipping, so it only ever ships what Magento still has open (an order
//     shipped in the Magento admin, or a lost reply, is never shipped twice).
//   → delivered; for cash on delivery the money is recorded on the invoice's
//     customer account. Bank transfer / UPI orders are also on the customer's
//     account until staff record the payment ("Payment received").
//   → the Magento invoice (capture off, no email) is created by the same worker
//     once the POS knows the money is in: at "Invoice & pack" for gateway
//     prepaid orders, at "Payment received" for bank transfer / UPI, and at
//     "Delivered" for cash on delivery.
// Cancellations or refunds on Magento after the POS invoice flag the order
// "credit note needed" and hold a shipment that was not sent yet.
// Voiding the POS invoice of an order that has not shipped puts the order back
// to "To pick" (its units are reserved again and it can be invoiced again).
// If the goods already left, the order keeps the voided invoice and no cash on
// delivery can be collected against it.
import type { FastifyInstance } from "fastify";
import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { type Actor, allow, audit, fail, id, integer, inventory, now, text } from "./domain.js";
import { finalizeSale } from "./sales.js";
import { onlineSaleBody, onlineShiftId, ONLINE_TENDER } from "./hooks/online-channel.js";
import { applyOnlineOrder, orderState } from "./magento-orders.js";
import { magentoConfig, queueMagentoSync } from "./online-queue.js";
import { magentoRequest, MagentoError } from "./magento.js";
import { payment } from "./purchasing.js";
import type { Post } from "./routes/types.js";

type Fetch = typeof globalThis.fetch;
const MANAGERS = ["owner", "manager"];

// ---------- GST state of the delivery address ----------

const STATES: [string, string, string][] = [
  ["01", "JK", "Jammu and Kashmir"], ["02", "HP", "Himachal Pradesh"], ["03", "PB", "Punjab"],
  ["04", "CH", "Chandigarh"], ["05", "UK", "Uttarakhand"], ["06", "HR", "Haryana"], ["07", "DL", "Delhi"],
  ["08", "RJ", "Rajasthan"], ["09", "UP", "Uttar Pradesh"], ["10", "BR", "Bihar"], ["11", "SK", "Sikkim"],
  ["12", "AR", "Arunachal Pradesh"], ["13", "NL", "Nagaland"], ["14", "MN", "Manipur"], ["15", "MZ", "Mizoram"],
  ["16", "TR", "Tripura"], ["17", "ML", "Meghalaya"], ["18", "AS", "Assam"], ["19", "WB", "West Bengal"],
  ["20", "JH", "Jharkhand"], ["21", "OR", "Odisha"], ["22", "CT", "Chhattisgarh"], ["23", "MP", "Madhya Pradesh"],
  ["24", "GJ", "Gujarat"], ["26", "DN", "Dadra and Nagar Haveli and Daman and Diu"], ["27", "MH", "Maharashtra"],
  ["29", "KA", "Karnataka"], ["30", "GA", "Goa"], ["31", "LD", "Lakshadweep"], ["32", "KL", "Kerala"],
  ["33", "TN", "Tamil Nadu"], ["34", "PY", "Puducherry"], ["35", "AN", "Andaman and Nicobar Islands"],
  ["36", "TG", "Telangana"], ["37", "AP", "Andhra Pradesh"], ["38", "LA", "Ladakh"],
];
const squash = (value: unknown) => String(value ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
const ALIASES: Record<string, string> = { OD: "21", CG: "22", TS: "36", UA: "05", ORISSA: "21", PONDICHERRY: "34", DAMANANDDIU: "26", DD: "26" };

/** The two-digit GST state code of a Magento region (code like "MH" or a state name). */
export function gstStateCode(...values: unknown[]) {
  for (const value of values) {
    const key = squash(value);
    if (!key) continue;
    if (/^\d{2}$/.test(key) && STATES.some(([code]) => code === key)) return key;
    if (ALIASES[key]) return ALIASES[key];
    const found = STATES.find(([, short, name]) => short === key || squash(name) === key);
    if (found) return found[0];
  }
  return "";
}

/** Cash on delivery (Magento's "cashondelivery", or a method titled that way). */
export function isCashOnDelivery(payment: any) {
  const method = String(payment?.method || "").toLowerCase();
  const title = String(payment?.title || "").toLowerCase();
  return method === "cashondelivery" || /\bcod\b|cash on delivery/.test(method + " " + title);
}

/**
 * How a website order is paid:
 *   "cod"     cash on delivery: on the customer's account until the courier pays;
 *   "prepaid" a payment gateway already collected it (only the Magento payment
 *             codes listed in Magento settings › prepaidMethods; none by default);
 *   "bank"    bank transfer / UPI / anything else: on the customer's account until
 *             staff record the payment with its reference ("Payment received").
 */
export function paymentKind(payment: any, config: any = {}): "cod" | "prepaid" | "bank" {
  if (isCashOnDelivery(payment)) return "cod";
  const method = String(payment?.method || "").toLowerCase();
  const prepaid = (Array.isArray(config.prepaidMethods) ? config.prepaidMethods : []).map((m: unknown) => String(m).toLowerCase());
  if (method === "free" || prepaid.includes(method)) return "prepaid";
  return "bank";
}

const rupees = (paise: number) => `₹${(paise / 100).toFixed(2)}`;

// ---------- helpers ----------

/** The branch's online till: not a cash drawer, never closed, hidden from shift lists. */
async function onlineShift(db: Database, actor: Actor) {
  const shiftId = onlineShiftId(actor.branchId);
  const existing = await getRecord(db, actor.organizationId, "shift", shiftId);
  if (existing) return existing;
  // Stored without a branch column (and without data.branchId) so it is never
  // listed with the branch's cash drawers; onlineBranchId names its branch.
  return putRecord(db, actor.organizationId, "shift", {
    id: shiftId,
    channel: "online",
    system: true,
    onlineBranchId: actor.branchId,
    userId: "online",
    openedAt: now(),
    openingCash: 0,
  });
}

/** The website customer as a POS customer (matched by email, then phone). */
async function onlineCustomer(db: Database, actor: Actor, order: any, stateCode: string) {
  const email = String(order.customer?.email || "").trim().toLowerCase();
  const phone = String(order.customer?.phone || "").replace(/\D/g, "");
  const customers = await records(db, actor.organizationId, "customer");
  const found =
    (email && customers.find((c) => String(c.email || "").toLowerCase() === email)) ||
    (phone.length >= 10 && customers.find((c) => String(c.phone || "").replace(/\D/g, "").endsWith(phone.slice(-10))));
  if (found) return found;
  return putRecord(db, actor.organizationId, "customer", {
    id: id("customer"),
    name: String(order.customer?.name || "Online customer").slice(0, 200),
    phone: String(order.customer?.phone || ""),
    email,
    address: String(order.shipTo || "").slice(0, 1000),
    taxRegistrationId: "",
    stateCode,
    vehicle: null,
    source: "online",
    openingBalance: 0,
    openingDate: "",
  });
}

async function branchOrder(db: Database, actor: Actor, orderId: string) {
  const order = await getRecord(db, actor.organizationId, "onlineOrder", orderId);
  if (!order) fail("Online order not found.", 404);
  if (order!.branchId !== actor.branchId) fail("Switch to the fulfilment branch for this order.", 409);
  return order!;
}

/** Units of a line still to ship: ordered, less cancelled, refunded and already invoiced. */
const toShip = (line: any) =>
  Math.max(0, Number(line.ordered || 0) - Number(line.canceled || 0) - Number(line.refunded || 0) - Number(line.posInvoiced || 0));

/** On-hand stock per sellable bin for each product (for picking). */
async function binsOnHand(db: Database, actor: Actor) {
  const locations = await records(db, actor.organizationId, "location", actor.branchId);
  const sellable = new Map(locations.filter((b) => b.kind === "sellable").map((b) => [b.id, b]));
  const rows = (
    await db.query("SELECT product_id, bin_id, quantity FROM stock WHERE organization_id=$1 AND branch_id=$2 AND quantity > 0", [
      actor.organizationId,
      actor.branchId,
    ])
  ).rows;
  const byProduct = new Map<string, { binId: string; location: string; onHand: number }[]>();
  for (const row of rows) {
    const bin = sellable.get(row.bin_id);
    if (!bin) continue;
    const list = byProduct.get(row.product_id) || [];
    list.push({ binId: bin.id, location: [bin.area, bin.rack, bin.shelf, bin.bin].filter(Boolean).join(" / "), onHand: Number(row.quantity) });
    byProduct.set(row.product_id, list.sort((a, b) => b.onHand - a.onHand));
  }
  return byProduct;
}

/** What to pick for [orders]: per order, and totalled per part for a batch pick. */
export async function pickList(db: Database, actor: Actor, orders: any[]) {
  const bins = await binsOnHand(db, actor);
  const products = new Map((await records(db, actor.organizationId, "product")).map((p) => [p.id, p]));
  const items = new Map<string, any>();
  const perOrder = orders.map((order) => ({
    id: order.id,
    number: order.number,
    customer: order.customer?.name || "",
    lines: (order.lines || [])
      .filter((line: any) => toShip(line) > 0)
      .map((line: any) => {
        const product = line.productId ? products.get(line.productId) : undefined;
        const qty = toShip(line);
        const row = {
          itemId: line.itemId,
          productId: line.productId || null,
          sku: product?.sku || line.sku,
          name: product?.name || line.name,
          qty,
          serialTracked: !!product?.serialTracked,
          barcodes: product?.barcodes || [],
          bins: product?.onlineOnly ? [] : (line.productId && bins.get(line.productId)) || [],
          // Online only: ordered from the supplier for this customer; nothing to pick.
          ...(product?.onlineOnly ? { onlineOnly: true, orderFromSupplier: true } : {}),
        };
        if (line.productId && !product?.onlineOnly) {
          const total = items.get(line.productId) || { ...row, qty: 0, orders: [] };
          total.qty += qty;
          total.orders.push({ id: order.id, number: order.number, itemId: line.itemId, qty });
          items.set(line.productId, total);
        }
        return row;
      }),
  }));
  // Walk the shop in bin order for a batch pick.
  const totals = [...items.values()].map(({ itemId, ...rest }) => rest)
    .sort((a, b) => String(a.bins[0]?.location || "~").localeCompare(String(b.bins[0]?.location || "~")) || a.sku.localeCompare(b.sku));
  return { orders: perOrder, items: totals };
}

/** What the customer paid on the website for [qty] units of an order line (GST included, after discount). */
export function rowPaid(line: any, qty: number) {
  const ordered = Number(line.ordered || 0);
  const row = line.rowPaid ?? Number(line.unitPaid ?? line.price ?? 0) * ordered;
  if (!ordered || qty >= ordered) return Math.round(Number(row));
  return Math.round((Number(row) * qty) / ordered);
}

/** Splits [total] over [weights] in proportion; the last share takes the residual paise. */
export function shares(total: number, weights: number[]) {
  const sum = weights.reduce((n, w) => n + w, 0);
  let given = 0;
  let cumulative = 0;
  return weights.map((w, i) => {
    cumulative += w;
    const upTo = i === weights.length - 1 || !sum ? total : Math.round((total * cumulative) / sum);
    const share = upTo - given;
    given = upTo;
    return share;
  });
}

/** Sale lines for the picked units: picked bins first, else the bins with the most stock. */
async function saleLines(db: Database, actor: Actor, order: any, picks: any[], sellBeyondStock: boolean) {
  const stock = await inventory(db, actor);
  const sellable = (await records(db, actor.organizationId, "location", actor.branchId)).filter((b) => b.kind === "sellable");
  const lines = new Map<string, any>();
  for (const line of order.lines) {
    const qty = toShip(line);
    if (!qty) continue;
    const product = await getRecord(db, actor.organizationId, "product", line.productId);
    if (product?.onlineOnly) {
      // Online only: invoiced as a non-stock line (no bin, no stock movement).
      const key = line.productId + "|";
      const saleLine = lines.get(key) || { productId: line.productId, binId: "", qty: 0, serials: [], onlineRowTotal: 0 };
      saleLine.qty += qty;
      saleLine.onlineRowTotal += rowPaid(line, qty);
      lines.set(key, saleLine);
      continue;
    }
    const mine = picks.filter((pick) => pick.itemId === line.itemId);
    if (!sellable.length) fail("Add a sellable bin first (Catalog › Bins).", 409);
    const picked = mine.reduce((n, pick) => n + pick.qty, 0);
    if (picked !== qty) fail(`Pick ${qty} × ${product?.name || line.sku} first (${picked} picked).`, 409);
    const serials = mine.flatMap((pick) => pick.serials);
    if (product?.serialTracked && (serials.length !== qty || new Set(serials).size !== qty))
      fail(`Scan the serial number of each ${product.name} picked.`, 409);
    if (!product?.serialTracked && serials.length) fail(`${product?.name || line.sku} does not take serial numbers.`);
    // Where this order line's units come from; its row total is shared over them afterwards.
    const parts: { binId: string; qty: number; serials: string[] }[] = [];
    const add = (binId: string, units: number, unitSerials: string[]) => {
      parts.push({ binId, qty: units, serials: unitSerials });
      const row = stock.find((s) => s.productId === line.productId && s.binId === binId);
      if (row) row.available -= units;
    };
    for (const pick of mine) {
      if (pick.binId) {
        const bin = sellable.find((b) => b.id === pick.binId);
        if (!bin) fail("Pick from a sellable bin of this branch.");
        add(pick.binId, pick.qty, pick.serials);
        continue;
      }
      if (pick.serials.length) {
        // A serial is in one bin: sell each from where it is.
        for (const serial of pick.serials) {
          const record = await getRecord(db, actor.organizationId, "serial", line.productId + ":" + serial);
          if (!record || record.status !== "available") fail(`Serial ${serial} is not in stock.`, 409);
          add(record!.binId, 1, [serial]);
        }
        continue;
      }
      let need = pick.qty;
      for (const row of stock
        .filter((s) => s.productId === line.productId && s.available > 0 && sellable.some((b) => b.id === s.binId))
        .sort((a, b) => b.available - a.available)) {
        if (need <= 0) break;
        const take = Math.min(need, row.available);
        add(row.binId, take, []);
        need -= take;
      }
      if (need > 0) {
        if (!sellBeyondStock) fail(`Only part of ${product?.name || line.sku} is in stock. Receive the goods first.`, 409);
        const home = stock.find((s) => s.productId === line.productId && sellable.some((b) => b.id === s.binId))?.binId || sellable[0].id;
        add(home, need, []);
      }
    }
    const amounts = shares(rowPaid(line, qty), parts.map((p) => p.qty));
    parts.forEach((part, i) => {
      const key = line.productId + "|" + part.binId;
      const saleLine = lines.get(key) || { productId: line.productId, binId: part.binId, qty: 0, serials: [], onlineRowTotal: 0 };
      saleLine.qty += part.qty;
      saleLine.serials.push(...part.serials);
      saleLine.onlineRowTotal += amounts[i];
      lines.set(key, saleLine);
    });
  }
  return [...lines.values()];
}

/** allowNone: every line is online only (ordered from the supplier), so nothing is picked. */
function readPicks(value: unknown, allowNone = false) {
  if (allowNone && (value === undefined || value === null || (Array.isArray(value) && !value.length))) return [];
  if (!Array.isArray(value) || !value.length) fail("Pick the items before invoicing.");
  return (value as any[]).map((pick) => ({
    itemId: pick.itemId,
    qty: integer(pick.qty, "Picked quantity", 1, 100000),
    binId: pick.binId ? text(pick.binId, "bin", true, 200) : null,
    serials: Array.isArray(pick.serials) ? pick.serials.map((s: unknown) => text(s, "serial")) : [],
  }));
}

// ---------- credit notes, voids and Magento jobs (database only) ----------

/** Credit notes made against [invoiceId]: their total, and whether the invoice was voided. */
async function creditNotes(db: Database, actor: Actor, invoiceId: string) {
  const notes = (await records(db, actor.organizationId, "return", actor.branchId)).filter((r) => r.invoiceId === invoiceId);
  return {
    voided: notes.some((r) => r.voided),
    total: notes.filter((r) => !r.voided).reduce((n, r) => n + Number(r.total || 0), 0),
    units: notes.flatMap((r) => r.lines || []).reduce((n: number, l: any) => n + Number(l.quantity || 0), 0),
  };
}

/** What the customer still owes on the order's invoice: [owed] less credit notes. Refused once voided. */
async function stillDue(db: Database, actor: Actor, f: any, owed: number) {
  const notes = await creditNotes(db, actor, f.invoiceId);
  if (notes.voided) fail(`Invoice ${f.invoiceNumber} was voided, so no payment can be recorded against it.`, 409);
  return Math.max(0, Number(owed || 0) - notes.total);
}

const MAGENTO_JOBS = { shipment: "magentoShipment", invoice: "magentoInvoice" } as const;

/** Queues (or re-queues) a Magento job for the order. */
async function queueJob(db: Database, organizationId: string, kind: string, orderId: string) {
  const job = await getRecord(db, organizationId, kind, orderId);
  await putRecord(db, organizationId, kind, { id: orderId, orderId, version: Number(job?.version || 0) + 1, attempts: 0, nextAt: now() });
}

async function dropJob(db: Database, organizationId: string, kind: string, orderId: string) {
  await db.query("DELETE FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3", [organizationId, kind, orderId]);
}

/** A worker is sending this job to Magento right now. */
const inFlight = (job: any) => !!job?.claimedAt && Date.parse(job.nextAt) > Date.now();

/** The Magento invoice is created by the worker once the POS knows the money is in. */
async function queueMagentoInvoice(db: Database, organizationId: string, order: any) {
  if (order.mode !== "pos") return;
  const state = order.fulfilment?.magentoInvoice?.state;
  if (state === "sent" || state === "skipped") return;
  order.fulfilment.magentoInvoice = { state: "queued", queuedAt: now(), attempts: 0, error: null };
  await queueJob(db, organizationId, MAGENTO_JOBS.invoice, order.id);
}

/**
 * The POS invoice of an online order was voided (called from invoices/:id/void).
 * Not shipped yet: the order goes back to "To pick" — the voided units are reserved
 * again, queued Magento jobs are dropped and the order can be invoiced again.
 * Already shipped: the goods are gone, so the order keeps the invoice, marked voided,
 * and no cash on delivery or transfer can be recorded against it.
 */
export async function onlineInvoiceVoided(db: Database, actor: Actor, invoice: any) {
  if (invoice?.channel !== "online" || !invoice.onlineOrderId) return;
  const order = await getRecord(db, actor.organizationId, "onlineOrder", invoice.onlineOrderId);
  const f = order?.fulfilment;
  if (!order || f?.invoiceId !== invoice.id) return;
  const record = { invoiceId: invoice.id, invoiceNumber: f.invoiceNumber, at: now(), by: actor.id };
  if (f.shipment?.state === "sent" || f.status === "delivered") {
    order.fulfilment = { ...f, invoiceVoided: record };
  } else {
    for (const line of order.lines || []) {
      const units = f.invoicedUnits ? Number(f.invoicedUnits[line.itemId] || 0) : Number(line.posInvoiced || 0);
      line.posInvoiced = Math.max(0, Number(line.posInvoiced || 0) - units);
      line.creditNoteQty = 0;
    }
    await dropJob(db, actor.organizationId, MAGENTO_JOBS.shipment, order.id);
    await dropJob(db, actor.organizationId, MAGENTO_JOBS.invoice, order.id);
    order.fulfilment = { status: "new", voidedInvoices: [...(f.voidedInvoices || []), record] };
    order.previousHeld = Object.fromEntries(
      (order.lines || []).filter((l: any) => l.productId).map((l: any) => [l.productId, (l.reserved || 0) + (l.awaiting || 0)]),
    );
    await applyOnlineOrder(db, order, order.branchId);
  }
  await putRecord(db, actor.organizationId, "onlineOrder", order, order.branchId);
  await audit(db, actor, "online-invoice-void", order.id, `Invoice ${f.invoiceNumber} of online order #${order.number} voided`, record);
}

// ---------- routes ----------

export function fulfilmentRoutes(app: FastifyInstance, db: Database, post: Post, fetchImpl: () => Fetch) {
  app.get("/api/v1/online-orders/pick-list", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, MANAGERS);
    const ids = String(request.query?.ids || "").split(",").map((v) => v.trim()).filter(Boolean).slice(0, 100);
    return db.readSnapshot(async (tx) => {
      const orders = [];
      for (const orderId of ids) orders.push(await branchOrder(tx, actor, orderId));
      if (!orders.length) fail("Choose the orders to pick.");
      return pickList(tx, actor, orders);
    });
  });

  /** Invoice & pack: the GST invoice for the picked units. */
  post("online-orders/:id/invoice", async (tx, actor, body, params) => {
    allow(actor, MANAGERS);
    let order = await branchOrder(tx, actor, String(params.id));
    // An invoice voided before voids reset the order: reset it now.
    if (order.fulfilment?.invoiceId && order.fulfilment.shipment?.state !== "sent" && (await creditNotes(tx, actor, order.fulfilment.invoiceId)).voided) {
      await onlineInvoiceVoided(tx, actor, await getRecord(tx, actor.organizationId, "invoice", order.fulfilment.invoiceId));
      order = await branchOrder(tx, actor, String(params.id));
    }
    if (order.fulfilment?.invoiceId) fail(`This order is already invoiced (${order.fulfilment.invoiceNumber}).`, 409);
    if (order.mode !== "pos")
      fail("Stock for this older order was taken when Magento invoiced it. Ship it without a POS invoice.", 409);
    // Parts added to the catalogue after the order arrived are matched now.
    const products = await records(tx, actor.organizationId, "product");
    for (const line of order.lines) {
      if (!line.productId) line.productId = products.find((p) => p.sku === line.sku)?.id || null;
    }
    const due = order.lines.filter((line: any) => toShip(line) > 0);
    if (!due.length) fail("Nothing is left to invoice on this order (it was cancelled or refunded).", 409);
    const unknown = due.find((line: any) => !line.productId);
    if (unknown) fail(`${unknown.sku} is not in the POS catalogue. Add a part with SKU ${unknown.sku}, then invoice the order.`, 409);
    // Website shipping charge, billed on a service part with SKU "SHIPPING".
    const shipping = products.find((p) => p.type === "service" && String(p.sku).toUpperCase() === "SHIPPING");
    const shippingCharge = Math.max(0, Number(order.shippingCharge || 0));
    if (shippingCharge > 0 && !shipping)
      fail(
        `This order has a shipping charge of ${rupees(shippingCharge)}. Create a service part with SKU SHIPPING ` +
          "(Catalog › Parts, type Service, with its SAC code and GST rate) so it can be billed, then invoice the order.",
        409,
      );
    const onlineOnlyIds = new Set(products.filter((p) => p.onlineOnly).map((p) => p.id));
    const picks = readPicks(body.picks, due.every((line: any) => onlineOnlyIds.has(line.productId)));
    // Release this order's hold so its units can be sold to it.
    for (const line of due) line.reserved = 0;
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    const settings = await getRecord(tx, actor.organizationId, "settings", "settings");
    const lines = await saleLines(tx, actor, order, picks, settings?.features?.negativeStock !== false);
    if (shipping && shippingCharge > 0)
      lines.push({ productId: shipping.id, qty: 1, binId: "", serials: [], onlineRowTotal: shippingCharge });
    // The website total for what is invoiced now (the whole order unless part was cancelled first).
    const fullOrder = order.lines.every((line: any) => toShip(line) === Number(line.ordered || 0));
    const onlineTotal = fullOrder && Number(order.total) > 0 ? Number(order.total) : undefined;
    const placeOfSupply = body.placeOfSupply
      ? text(body.placeOfSupply, "place of supply", true, 50)
      : gstStateCode(order.shipRegionCode, order.shipRegion);
    const customer = await onlineCustomer(tx, actor, order, placeOfSupply);
    const kind = paymentKind(order.payment, magentoConfig(settings));
    const shift = await onlineShift(tx, actor);
    const invoice = await finalizeSale(
      tx,
      actor,
      onlineSaleBody({
        transactionId: `online-${order.id}-${id("inv")}`,
        shiftId: shift.id,
        customerId: customer.id,
        placeOfSupply,
        lines,
        onlineTotal,
        tenders: [{
          type: kind === "prepaid" ? ONLINE_TENDER : "Credit",
          amount: Math.max(1, Number(order.total || 0)),
          confirmed: true,
          reference: `Magento #${order.number}${order.payment?.title ? " · " + order.payment.title : ""}${kind === "bank" ? " · awaiting payment" : ""}`.slice(0, 200),
        }],
        onlineOrder: { id: order.id, number: order.number, paymentMethod: order.payment?.title || order.payment?.method || "", paymentKind: kind },
      }),
    );
    const invoicedUnits: Record<string, number> = {};
    for (const line of due) {
      invoicedUnits[line.itemId] = toShip(line);
      line.posInvoiced = Number(line.posInvoiced || 0) + toShip(line);
      line.reserved = 0;
      line.shortage = 0;
    }
    order.fulfilment = {
      ...(order.fulfilment || {}),
      status: "packed",
      invoiceId: invoice.id,
      invoiceNumber: invoice.number,
      invoiceTotal: invoice.total,
      invoicedAt: invoice.createdAt,
      invoicedBy: actor.id,
      invoicedUnits,
      customerId: customer.id,
      paymentKind: kind,
      cod: kind === "cod",
      codDue: kind === "cod" ? invoice.total : 0,
      // Bank transfer / UPI: owed until staff record the payment.
      paymentDue: kind === "bank" ? invoice.total : 0,
      picks,
    };
    order.posState = orderState(order);
    if (kind === "prepaid") await queueMagentoInvoice(tx, actor.organizationId, order);
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    return { order, invoice };
  });

  /** Courier and tracking number: the shipment is queued for Magento. */
  post("online-orders/:id/ship", async (tx, actor, body, params) => {
    allow(actor, MANAGERS);
    const order = await branchOrder(tx, actor, String(params.id));
    const invoiced = !!order.fulfilment?.invoiceId;
    const olderSold = order.mode !== "pos" && order.posState === "sold";
    if (!invoiced && !olderSold) fail("Invoice and pack the order before shipping it.", 409);
    if (order.fulfilment?.shipment?.state === "sent") fail("This shipment is already on Magento.", 409);
    if (order.fulfilment?.creditNoteNeeded && !order.fulfilment.creditNoteNeeded.resolvedAt)
      fail("Part of this order was cancelled or refunded on the website. Make the credit note first.", 409);
    const courier = text(body.courier, "courier name", true, 80);
    const tracking = text(body.tracking, "tracking number", true, 100);
    const job = await getRecord(tx, actor.organizationId, MAGENTO_JOBS.shipment, order.id);
    if (inFlight(job)) fail("This shipment is being sent to Magento right now. Try again in a minute.", 409);
    order.fulfilment = {
      ...(order.fulfilment || {}),
      status: "shipping",
      shipment: { courier, tracking, state: "queued", attempts: 0, error: null, queuedAt: now(), queuedBy: actor.id },
    };
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    await queueJob(tx, actor.organizationId, MAGENTO_JOBS.shipment, order.id);
    return order;
  });

  /** Try again now after Magento refused or could not be reached (or after a hold was cleared). */
  post("online-orders/:id/shipment/retry", async (tx, actor, _body, params) => {
    allow(actor, MANAGERS);
    const order = await branchOrder(tx, actor, String(params.id));
    const shipment = order.fulfilment?.shipment;
    if (!shipment || shipment.state === "sent" || shipment.state === "cancelled") fail("There is no shipment waiting to be sent.", 409);
    if (order.fulfilment.creditNoteNeeded && !order.fulfilment.creditNoteNeeded.resolvedAt)
      fail("Part of this order was cancelled or refunded on the website. Make the credit note first.", 409);
    if (inFlight(await getRecord(tx, actor.organizationId, MAGENTO_JOBS.shipment, order.id)))
      fail("This shipment is being sent to Magento right now. Try again in a minute.", 409);
    await queueJob(tx, actor.organizationId, MAGENTO_JOBS.shipment, order.id);
    order.fulfilment.shipment = { ...shipment, state: "queued", attempts: 0 };
    return putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
  });

  /** "Send now": runs the Magento shipment and invoice worker for this shop (network calls outside transactions). */
  app.post("/api/v1/online-orders/shipments/push", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, MANAGERS);
    const options = { fetch: fetchImpl(), organizationId: actor.organizationId };
    const shipments = await runMagentoShipments(db, options);
    const invoices = await runMagentoInvoices(db, options);
    return { ...shipments, invoices };
  });

  /** Delivered. Cash on delivery: the money is recorded against the invoice's customer. */
  post("online-orders/:id/delivered", async (tx, actor, body, params) => {
    allow(actor, MANAGERS);
    const order = await branchOrder(tx, actor, String(params.id));
    const f = order.fulfilment || {};
    if (!f.shipment) fail("Ship the order before marking it delivered.", 409);
    if (f.status === "delivered") fail("This order is already marked delivered.", 409);
    let collection = null;
    if (f.cod && Number(f.codDue) > 0) {
      // Less any credit notes on the invoice; nothing can be collected on a voided one
      // (the order can still be marked delivered, without a collection).
      const notes = await creditNotes(tx, actor, f.invoiceId);
      if ((f.invoiceVoided || notes.voided) && body.amount !== undefined && Number(body.amount) > 0)
        fail(`Invoice ${f.invoiceNumber} was voided, so no cash on delivery can be collected against it.`, 409);
      const due = f.invoiceVoided || notes.voided ? 0 : Math.max(0, Number(f.codDue) - notes.total);
      if (due > 0) {
        const amount = integer(body.amount ?? due, "Amount collected", 1, due);
        collection = await payment(
          tx,
          actor,
          {
            amount,
            mode: body.mode || "Bank transfer",
            reference: text(body.reference || `COD #${order.number}`, "reference", false, 120),
            notes: `Cash on delivery for online order #${order.number}, invoice ${f.invoiceNumber}`,
            // Cash handed in at the counter goes through the drawer only when asked.
            fromDrawer: body.fromDrawer === true,
          },
          "customer",
          f.customerId,
          { invoiceId: f.invoiceId, onlineOrderId: order.id },
        );
        f.codDue = Number(f.codDue) - amount;
        f.codPayments = [...(f.codPayments || []), collection.id];
      }
    }
    order.fulfilment = { ...f, status: "delivered", deliveredAt: now(), deliveredBy: actor.id };
    if (f.cod && !f.invoiceVoided) await queueMagentoInvoice(tx, actor.organizationId, order);
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    return { order, payment: collection };
  });

  /** Bank transfer / UPI: the customer's payment arrived. Recorded with its reference; Magento is then invoiced. */
  post("online-orders/:id/payment-received", async (tx, actor, body, params) => {
    allow(actor, MANAGERS);
    const order = await branchOrder(tx, actor, String(params.id));
    const f = order.fulfilment || {};
    if (!f.invoiceId) fail("Invoice and pack the order before recording its payment.", 409);
    if (f.paymentKind !== "bank") fail("This order is not waiting for a bank transfer or UPI payment.", 409);
    if (f.invoiceVoided) fail(`Invoice ${f.invoiceNumber} was voided, so no payment can be recorded against it.`, 409);
    const due = await stillDue(tx, actor, f, f.paymentDue);
    if (due <= 0) fail(`Nothing is left to pay on invoice ${f.invoiceNumber}.`, 409);
    const reference = text(body.reference, "UPI / bank transfer reference", true, 120);
    const amount = integer(body.amount ?? due, "Amount received", 1, due);
    const record = await payment(
      tx,
      actor,
      {
        amount,
        mode: body.mode || "UPI",
        reference,
        notes: `Payment for online order #${order.number}, invoice ${f.invoiceNumber}`,
        fromDrawer: false,
        date: body.date,
      },
      "customer",
      f.customerId,
      { invoiceId: f.invoiceId, onlineOrderId: order.id },
    );
    f.paymentDue = Number(f.paymentDue) - amount;
    f.payments = [...(f.payments || []), record.id];
    f.paidAt = due - amount <= 0 ? now() : f.paidAt || null;
    order.fulfilment = f;
    if (due - amount <= 0) await queueMagentoInvoice(tx, actor.organizationId, order);
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    return { order, payment: record };
  });

  /** The credit note for a cancellation or refund on Magento was made (or is not needed, with a reason). */
  post("online-orders/:id/credit-note/resolve", async (tx, actor, body, params) => {
    allow(actor, MANAGERS);
    const order = await branchOrder(tx, actor, String(params.id));
    const f = order.fulfilment || {};
    const flag = f.creditNoteNeeded;
    if (!flag || flag.resolvedAt) fail("This order does not need a credit note.", 409);
    const notes = await creditNotes(tx, actor, flag.invoiceId);
    const flagged = (flag.lines || []).reduce((n: number, l: any) => n + Number(l.qty || 0), 0);
    const reason = String(body.reason || "").trim();
    if (!notes.voided && notes.units < flagged && !reason)
      fail(`Make the credit note for invoice ${flag.invoiceNumber} first (Orders › Returns & exchange), or give a reason why none is needed.`, 409);
    f.creditNoteNeeded = { ...flag, resolvedAt: now(), resolvedBy: actor.id, reason: reason ? text(reason, "reason", true, 200) : "" };
    order.fulfilment = f;
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    return order;
  });
}

// ---------- Magento worker (shipments and invoices) ----------

const MAX_ATTEMPTS = 8;
const LEASE_MS = 5 * 60_000;
const backoffMs = (attempts: number) => Math.min(2 ** attempts * 30_000, 3_600_000);

async function dueJobs(db: Database, kind: string, options: { organizationId?: string; limit?: number }) {
  return (
    await db.query(
      "SELECT organization_id, data FROM records WHERE kind=$1 AND data->>'nextAt' <= $2" +
        (options.organizationId ? " AND organization_id=$4" : "") +
        " ORDER BY data->>'nextAt' LIMIT $3",
      options.organizationId
        ? [kind, new Date().toISOString(), options.limit || 20, options.organizationId]
        : [kind, new Date().toISOString(), options.limit || 20],
    )
  ).rows as { organization_id: string; data: any }[];
}

/**
 * Claims a due job in a short transaction before anything is sent: its nextAt moves
 * a lease into the future, so another worker (or "Send now") does not send it too.
 * A worker that dies mid-send is retried when the lease runs out; the Magento order
 * is read first then, so nothing is sent twice.
 */
async function claimJob(db: Database, org: string, kind: string, job: any): Promise<any> {
  return db.transaction(async (tx) => {
    const current = await getRecord(tx, org, kind, job.id);
    if (!current || current.version !== job.version || String(current.nextAt) > new Date().toISOString()) return null;
    const claimed = { ...current, claimedAt: now(), nextAt: new Date(Date.now() + LEASE_MS).toISOString() };
    await putRecord(tx, org, kind, claimed);
    return claimed;
  });
}

async function magentoConnection(db: Database, org: string) {
  const config = magentoConfig(await getRecord(db, org, "settings", "settings"));
  const secret = await getRecord(db, org, "integrationSecret", "magento");
  if (!config.enabled || !config.baseUrl || !secret?.token) throw new MagentoError("Magento is not connected.");
  return { config, token: secret.token as string };
}

/** The order's own items in Magento (not the child rows of configurable products). */
const magentoItems = (mg: any) => new Map<unknown, any>((mg?.items || []).filter((i: any) => !i.parent_item_id).map((i: any) => [i.item_id, i]));
const q = (item: any, field: string) => Number(item?.[field] || 0);

/**
 * What to ship now, per Magento item: what Magento still has open (ordered less
 * shipped, cancelled and refunded), and for POS-invoiced orders no more than the
 * POS invoiced. Never a line with quantity 0.
 */
export function shipmentItems(order: any, mg: any) {
  const items = magentoItems(mg);
  const out: { order_item_id: unknown; qty: number }[] = [];
  for (const line of order.lines || []) {
    const item = items.get(line.itemId);
    if (!item) continue;
    const open = q(item, "qty_ordered") - q(item, "qty_shipped") - q(item, "qty_canceled") - q(item, "qty_refunded");
    const wanted = order.mode === "pos" ? Number(line.posInvoiced || 0) - q(item, "qty_shipped") : open;
    const qty = Math.min(open, wanted);
    if (qty > 0) out.push({ order_item_id: line.itemId, qty });
  }
  return out;
}

const shippedAnything = (mg: any) => [...magentoItems(mg).values()].some((item) => q(item, "qty_shipped") > 0);

type ShipOutcome =
  | { kind: "sent"; shipmentId: unknown; note: string | null; alreadyShipped: boolean }
  | { kind: "cancelled"; note: string };

/** Nothing left to ship on Magento: it was shipped there already (add our tracking if missing), or cancelled. */
async function alreadyShipped(fetchImpl: Fetch, baseUrl: string, token: string, order: any, mg: any): Promise<ShipOutcome> {
  if (!shippedAnything(mg)) return { kind: "cancelled", note: "Nothing is left to ship on Magento (cancelled or refunded there)." };
  const { courier, tracking } = order.fulfilment.shipment;
  const search = new URLSearchParams({
    "searchCriteria[filter_groups][0][filters][0][field]": "order_id",
    "searchCriteria[filter_groups][0][filters][0][value]": String(order.magentoId),
    "searchCriteria[filter_groups][0][filters][0][condition_type]": "eq",
  });
  const found = await magentoRequest(fetchImpl, baseUrl, token, "GET", `/V1/shipments?${search}`);
  const shipments: any[] = found?.items || [];
  const ours = shipments.find((s) => (s.tracks || []).some((t: any) => String(t.track_number) === tracking));
  if (ours) return { kind: "sent", shipmentId: ours.entity_id ?? null, note: "Already on Magento with this tracking number.", alreadyShipped: true };
  const latest = shipments[shipments.length - 1];
  if (!latest) return { kind: "sent", shipmentId: null, note: "Magento shows the order as shipped. Add the tracking number in the Magento admin.", alreadyShipped: true };
  await magentoRequest(fetchImpl, baseUrl, token, "POST", "/V1/shipment/track", {
    entity: { order_id: order.magentoId, parent_id: latest.entity_id, track_number: tracking, title: courier, carrier_code: "custom" },
  });
  return { kind: "sent", shipmentId: latest.entity_id ?? null, note: "Already shipped in Magento; the tracking number was added to that shipment.", alreadyShipped: true };
}

/** Sends due shipments (with tracking) to Magento. Network calls happen outside transactions. */
export async function runMagentoShipments(db: Database, options: { fetch?: Fetch; organizationId?: string; limit?: number } = {}) {
  const fetchImpl = options.fetch || globalThis.fetch;
  let sent = 0;
  let failed = 0;
  for (const { organization_id: org, data: due } of await dueJobs(db, MAGENTO_JOBS.shipment, options)) {
    const job = await claimJob(db, org, MAGENTO_JOBS.shipment, due);
    if (!job) continue;
    const order = await getRecord(db, org, "onlineOrder", job.orderId);
    let error: string | null = null;
    let outcome: ShipOutcome | null = null;
    try {
      const { config, token } = await magentoConnection(db, org);
      if (!order?.fulfilment?.shipment) throw new MagentoError("The online order is no longer in the POS.");
      const { courier, tracking } = order.fulfilment.shipment;
      const path = `/V1/orders/${order.magentoId}`;
      const before = await magentoRequest(fetchImpl, config.baseUrl, token, "GET", path);
      const items = shipmentItems(order, before);
      if (!items.length) outcome = await alreadyShipped(fetchImpl, config.baseUrl, token, order, before);
      else {
        try {
          const shipmentId = await magentoRequest(fetchImpl, config.baseUrl, token, "POST", `/V1/order/${order.magentoId}/ship`, {
            items,
            notify: true,
            appendComment: true,
            comment: { comment: `Shipped by ${courier}. Tracking number ${tracking}.`, is_visible_on_front: 1 },
            tracks: [{ track_number: tracking, title: courier, carrier_code: "custom" }],
            // MSI: ship from the configured source (Magento uses its default source otherwise).
            ...(config.sourceCode ? { arguments: { extension_attributes: { source_code: config.sourceCode } } } : {}),
          });
          outcome = { kind: "sent", shipmentId, note: null, alreadyShipped: false };
        } catch (e) {
          // The shipment may have been made with the reply lost: read the order again.
          const after = await magentoRequest(fetchImpl, config.baseUrl, token, "GET", path).catch(() => null);
          if (!after || shipmentItems(order, after).length || !shippedAnything(after)) throw e;
          outcome = await alreadyShipped(fetchImpl, config.baseUrl, token, order, after);
        }
      }
      sent++;
    } catch (e: any) {
      error = e instanceof MagentoError ? e.message : `Shipment failed: ${e?.message || e}`;
      failed++;
    }
    await db.transaction(async (tx) => {
      const current = await getRecord(tx, org, MAGENTO_JOBS.shipment, job.id);
      if (current && current.version !== job.version) return; // tracking changed meanwhile; that send runs next
      const fresh = await getRecord(tx, org, "onlineOrder", job.orderId);
      const attempts = Number(job.attempts || 0) + 1;
      const giveUp = !!error && attempts >= MAX_ATTEMPTS;
      // Dropped meanwhile (a cancellation on Magento held it): only a completed send is recorded.
      if (!current && error) return;
      if (fresh?.fulfilment?.shipment) {
        const shipment = fresh.fulfilment.shipment;
        if (error)
          fresh.fulfilment.shipment = {
            ...shipment,
            state: giveUp ? "failed" : "error",
            error,
            attempts,
            nextAt: giveUp ? null : new Date(Date.now() + backoffMs(attempts)).toISOString(),
          };
        else if (outcome?.kind === "cancelled")
          fresh.fulfilment.shipment = { ...shipment, state: "cancelled", error: outcome.note, attempts };
        else if (outcome?.kind === "sent") {
          fresh.fulfilment.shipment = {
            ...shipment,
            state: "sent",
            error: null,
            attempts,
            magentoShipmentId: outcome.shipmentId,
            alreadyShipped: outcome.alreadyShipped,
            note: outcome.note,
            sentAt: now(),
          };
          if (fresh.fulfilment.status !== "delivered") fresh.fulfilment.status = "shipped";
        }
        await putRecord(tx, org, "onlineOrder", fresh, fresh.branchId);
        // MSI: Magento has now taken the shipped units off its source and dropped its
        // reservation; send the POS stock again so the website quantity is right.
        if (outcome?.kind === "sent")
          await queueMagentoSync(tx, org, (fresh.lines || []).map((l: any) => l.productId).filter(Boolean), "online-shipment", fresh.branchId);
      }
      if (error && !giveUp) {
        const { claimedAt: _claimed, ...rest } = current!;
        await putRecord(tx, org, MAGENTO_JOBS.shipment, { ...rest, attempts, error, nextAt: new Date(Date.now() + backoffMs(attempts)).toISOString() });
      } else await dropJob(tx, org, MAGENTO_JOBS.shipment, job.id);
    });
  }
  return { sent, failed };
}

/** Nothing left to invoice on Magento (invoiced in its admin, by a gateway, or by an earlier lost reply). */
const invoiceDone = (mg: any) =>
  ![...magentoItems(mg).values()].some((item) => q(item, "qty_ordered") - q(item, "qty_canceled") - q(item, "qty_invoiced") > 0);

/** Creates due Magento invoices (no capture, no email). Network calls happen outside transactions. */
export async function runMagentoInvoices(db: Database, options: { fetch?: Fetch; organizationId?: string; limit?: number } = {}) {
  const fetchImpl = options.fetch || globalThis.fetch;
  let sent = 0;
  let failed = 0;
  for (const { organization_id: org, data: due } of await dueJobs(db, MAGENTO_JOBS.invoice, options)) {
    const job = await claimJob(db, org, MAGENTO_JOBS.invoice, due);
    if (!job) continue;
    const order = await getRecord(db, org, "onlineOrder", job.orderId);
    let error: string | null = null;
    let result: { state: "sent" | "skipped"; magentoInvoiceId: unknown } | null = null;
    try {
      const { config, token } = await magentoConnection(db, org);
      if (!order) throw new MagentoError("The online order is no longer in the POS.");
      const path = `/V1/orders/${order.magentoId}`;
      if (invoiceDone(await magentoRequest(fetchImpl, config.baseUrl, token, "GET", path))) result = { state: "skipped", magentoInvoiceId: null };
      else {
        try {
          const invoiceId = await magentoRequest(fetchImpl, config.baseUrl, token, "POST", `/V1/order/${order.magentoId}/invoice`, {
            capture: false,
            notify: false,
          });
          result = { state: "sent", magentoInvoiceId: invoiceId };
        } catch (e) {
          const after = await magentoRequest(fetchImpl, config.baseUrl, token, "GET", path).catch(() => null);
          if (!after || !invoiceDone(after)) throw e;
          result = { state: "skipped", magentoInvoiceId: null };
        }
      }
      sent++;
    } catch (e: any) {
      error = e instanceof MagentoError ? e.message : `Magento invoice failed: ${e?.message || e}`;
      failed++;
    }
    await db.transaction(async (tx) => {
      const current = await getRecord(tx, org, MAGENTO_JOBS.invoice, job.id);
      if (!current || current.version !== job.version) return;
      const fresh = await getRecord(tx, org, "onlineOrder", job.orderId);
      const attempts = Number(job.attempts || 0) + 1;
      const giveUp = !!error && attempts >= MAX_ATTEMPTS;
      if (fresh?.fulfilment) {
        fresh.fulfilment.magentoInvoice = error
          ? { ...(fresh.fulfilment.magentoInvoice || {}), state: giveUp ? "failed" : "error", error, attempts }
          : { ...(fresh.fulfilment.magentoInvoice || {}), ...result, error: null, attempts, at: now() };
        await putRecord(tx, org, "onlineOrder", fresh, fresh.branchId);
      }
      if (error && !giveUp) {
        const { claimedAt: _claimed, ...rest } = current;
        await putRecord(tx, org, MAGENTO_JOBS.invoice, { ...rest, attempts, error, nextAt: new Date(Date.now() + backoffMs(attempts)).toISOString() });
      } else await dropJob(tx, org, MAGENTO_JOBS.invoice, job.id);
    });
  }
  return { sent, failed };
}

/** Sends shipments and Magento invoices every [intervalMs] in the API process. Returns a stop function. */
export function startShipmentWorker(db: Database, intervalMs = 15_000) {
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await runMagentoShipments(db);
      await runMagentoInvoices(db);
    } catch (error) {
      console.error("Magento shipment error", error);
    } finally {
      running = false;
    }
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}
