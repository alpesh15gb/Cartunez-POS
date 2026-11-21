// WS-E: online order fulfilment. The POS invoices website orders:
//   Magento order arrives (stock reserved, magento-orders.ts)
//   → pick list (per order, or a batch of orders), picked by scanning
//   → "Invoice & pack": a GST invoice through the normal checkout pipeline on
//     the branch's online till (hooks/online-channel.ts); the reservation turns
//     into the sale's stock movement
//   → courier and tracking number → the shipment is sent to Magento by a worker
//     (never inside a database transaction), retried when Magento fails
//   → delivered; for cash on delivery the money is recorded on the invoice's
//     customer account.
import type { FastifyInstance } from "fastify";
import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { type Actor, allow, fail, id, integer, inventory, now, text } from "./domain.js";
import { finalizeSale } from "./sales.js";
import { onlineSaleBody, onlineShiftId, ONLINE_TENDER } from "./hooks/online-channel.js";
import { orderState } from "./magento-orders.js";
import { magentoConfig } from "./online-queue.js";
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
          bins: (line.productId && bins.get(line.productId)) || [],
        };
        if (line.productId) {
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

/** Sale lines for the picked units: picked bins first, else the bins with the most stock. */
async function saleLines(db: Database, actor: Actor, order: any, picks: any[], sellBeyondStock: boolean) {
  const stock = await inventory(db, actor);
  const sellable = (await records(db, actor.organizationId, "location", actor.branchId)).filter((b) => b.kind === "sellable");
  if (!sellable.length) fail("Add a sellable bin first (Catalog › Bins).", 409);
  const lines = new Map<string, any>();
  const add = (productId: string, binId: string, qty: number, serials: string[], onlinePrice: number) => {
    const key = productId + "|" + binId;
    const line = lines.get(key) || { productId, binId, qty: 0, serials: [], onlinePrice };
    line.qty += qty;
    line.serials.push(...serials);
    lines.set(key, line);
    const row = stock.find((s) => s.productId === productId && s.binId === binId);
    if (row) row.available -= qty;
  };
  for (const line of order.lines) {
    const qty = toShip(line);
    if (!qty) continue;
    const product = await getRecord(db, actor.organizationId, "product", line.productId);
    const mine = picks.filter((pick) => pick.itemId === line.itemId);
    const picked = mine.reduce((n, pick) => n + pick.qty, 0);
    if (picked !== qty) fail(`Pick ${qty} × ${product?.name || line.sku} first (${picked} picked).`, 409);
    const serials = mine.flatMap((pick) => pick.serials);
    if (product?.serialTracked && (serials.length !== qty || new Set(serials).size !== qty))
      fail(`Scan the serial number of each ${product.name} picked.`, 409);
    if (!product?.serialTracked && serials.length) fail(`${product?.name || line.sku} does not take serial numbers.`);
    const price = Number(line.unitPaid ?? line.price ?? 0);
    for (const pick of mine) {
      if (pick.binId) {
        const bin = sellable.find((b) => b.id === pick.binId);
        if (!bin) fail("Pick from a sellable bin of this branch.");
        add(line.productId, pick.binId, pick.qty, pick.serials, price);
        continue;
      }
      if (pick.serials.length) {
        // A serial is in one bin: sell each from where it is.
        for (const serial of pick.serials) {
          const record = await getRecord(db, actor.organizationId, "serial", line.productId + ":" + serial);
          if (!record || record.status !== "available") fail(`Serial ${serial} is not in stock.`, 409);
          add(line.productId, record!.binId, 1, [serial], price);
        }
        continue;
      }
      let need = pick.qty;
      for (const row of stock
        .filter((s) => s.productId === line.productId && s.available > 0 && sellable.some((b) => b.id === s.binId))
        .sort((a, b) => b.available - a.available)) {
        if (need <= 0) break;
        const take = Math.min(need, row.available);
        add(line.productId, row.binId, take, [], price);
        need -= take;
      }
      if (need > 0) {
        if (!sellBeyondStock) fail(`Only part of ${product?.name || line.sku} is in stock. Receive the goods first.`, 409);
        const home = stock.find((s) => s.productId === line.productId && sellable.some((b) => b.id === s.binId))?.binId || sellable[0].id;
        add(line.productId, home, need, [], price);
      }
    }
  }
  return [...lines.values()];
}

function readPicks(value: unknown) {
  if (!Array.isArray(value) || !value.length) fail("Pick the items before invoicing.");
  return (value as any[]).map((pick) => ({
    itemId: pick.itemId,
    qty: integer(pick.qty, "Picked quantity", 1, 100000),
    binId: pick.binId ? text(pick.binId, "bin", true, 200) : null,
    serials: Array.isArray(pick.serials) ? pick.serials.map((s: unknown) => text(s, "serial")) : [],
  }));
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
    const order = await branchOrder(tx, actor, String(params.id));
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
    const picks = readPicks(body.picks);
    // Release this order's hold so its units can be sold to it.
    for (const line of due) line.reserved = 0;
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    const settings = await getRecord(tx, actor.organizationId, "settings", "settings");
    const lines = await saleLines(tx, actor, order, picks, settings?.features?.negativeStock !== false);
    // Website shipping charge, billed on a service part with SKU "SHIPPING" when the shop has one.
    const shipping = products.find((p) => p.type === "service" && String(p.sku).toUpperCase() === "SHIPPING");
    if (shipping && Number(order.shippingCharge) > 0)
      lines.push({ productId: shipping.id, qty: 1, binId: "", serials: [], onlinePrice: Number(order.shippingCharge) });
    const placeOfSupply = body.placeOfSupply
      ? text(body.placeOfSupply, "place of supply", true, 50)
      : gstStateCode(order.shipRegionCode, order.shipRegion);
    const customer = await onlineCustomer(tx, actor, order, placeOfSupply);
    const cod = isCashOnDelivery(order.payment);
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
        tenders: [{
          type: cod ? "Credit" : ONLINE_TENDER,
          amount: Math.max(1, Number(order.total || 0)),
          confirmed: true,
          reference: `Magento #${order.number}${order.payment?.title ? " · " + order.payment.title : ""}`.slice(0, 200),
        }],
        onlineOrder: { id: order.id, number: order.number, paymentMethod: order.payment?.title || order.payment?.method || "" },
      }),
    );
    for (const line of due) {
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
      customerId: customer.id,
      cod,
      codDue: cod ? invoice.total : 0,
      picks,
    };
    order.posState = orderState(order);
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
    const courier = text(body.courier, "courier name", true, 80);
    const tracking = text(body.tracking, "tracking number", true, 100);
    const job = await getRecord(tx, actor.organizationId, "magentoShipment", order.id);
    const version = Number(job?.version || 0) + 1;
    order.fulfilment = {
      ...(order.fulfilment || {}),
      status: "shipping",
      shipment: { courier, tracking, state: "queued", attempts: 0, error: null, queuedAt: now(), queuedBy: actor.id },
    };
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    await putRecord(tx, actor.organizationId, "magentoShipment", { id: order.id, orderId: order.id, version, attempts: 0, nextAt: now() });
    return order;
  });

  /** Try again now after Magento refused or could not be reached. */
  post("online-orders/:id/shipment/retry", async (tx, actor, _body, params) => {
    allow(actor, MANAGERS);
    const order = await branchOrder(tx, actor, String(params.id));
    const shipment = order.fulfilment?.shipment;
    if (!shipment || shipment.state === "sent") fail("There is no shipment waiting to be sent.", 409);
    const job = await getRecord(tx, actor.organizationId, "magentoShipment", order.id);
    await putRecord(tx, actor.organizationId, "magentoShipment", {
      id: order.id, orderId: order.id, version: Number(job?.version || 0) + 1, attempts: 0, nextAt: now(),
    });
    order.fulfilment.shipment = { ...shipment, state: "queued", attempts: 0 };
    return putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
  });

  /** "Send now": runs the shipment worker for this shop (network calls outside transactions). */
  app.post("/api/v1/online-orders/shipments/push", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, MANAGERS);
    return runMagentoShipments(db, { fetch: fetchImpl(), organizationId: actor.organizationId });
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
      const amount = integer(body.amount ?? f.codDue, "Amount collected", 1, Number(f.codDue));
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
    order.fulfilment = { ...f, status: "delivered", deliveredAt: now(), deliveredBy: actor.id };
    await putRecord(tx, actor.organizationId, "onlineOrder", order, order.branchId);
    return { order, payment: collection };
  });
}

// ---------- shipment worker ----------

const MAX_ATTEMPTS = 8;
const backoffMs = (attempts: number) => Math.min(2 ** attempts * 30_000, 3_600_000);

/** Sends due shipments (with tracking) to Magento. Network calls happen outside transactions. */
export async function runMagentoShipments(db: Database, options: { fetch?: Fetch; organizationId?: string; limit?: number } = {}) {
  const fetchImpl = options.fetch || globalThis.fetch;
  const due = (
    await db.query(
      "SELECT organization_id, data FROM records WHERE kind='magentoShipment' AND data->>'nextAt' <= $1" +
        (options.organizationId ? " AND organization_id=$3" : "") +
        " ORDER BY data->>'nextAt' LIMIT $2",
      options.organizationId
        ? [new Date().toISOString(), options.limit || 20, options.organizationId]
        : [new Date().toISOString(), options.limit || 20],
    )
  ).rows as { organization_id: string; data: any }[];
  let sent = 0;
  let failed = 0;
  for (const { organization_id: org, data: job } of due) {
    const config = magentoConfig(await getRecord(db, org, "settings", "settings"));
    const secret = await getRecord(db, org, "integrationSecret", "magento");
    const order = await getRecord(db, org, "onlineOrder", job.orderId);
    let error: string | null = null;
    let shipmentId: unknown = null;
    try {
      if (!config.enabled || !config.baseUrl || !secret?.token) throw new MagentoError("Magento is not connected.");
      if (!order?.fulfilment?.shipment) throw new MagentoError("The online order is no longer in the POS.");
      const { courier, tracking } = order.fulfilment.shipment;
      const items = (order.lines || [])
        .map((line: any) => ({
          order_item_id: line.itemId,
          qty: Math.max(0, Number(line.ordered || 0) - Number(line.canceled || 0) - Number(line.refunded || 0)),
        }))
        .filter((item: any) => item.order_item_id && item.qty > 0);
      shipmentId = await magentoRequest(fetchImpl, config.baseUrl, secret.token, "POST", `/V1/order/${order.magentoId}/ship`, {
        items,
        notify: true,
        appendComment: true,
        comment: { comment: `Shipped by ${courier}. Tracking number ${tracking}.`, is_visible_on_front: 1 },
        tracks: [{ track_number: tracking, title: courier, carrier_code: "custom" }],
      });
      sent++;
    } catch (e: any) {
      error = e instanceof MagentoError ? e.message : `Shipment failed: ${e?.message || e}`;
      failed++;
    }
    await db.transaction(async (tx) => {
      const current = await getRecord(tx, org, "magentoShipment", job.id);
      if (!current || current.version !== job.version) return; // tracking changed meanwhile; that send runs next
      const fresh = await getRecord(tx, org, "onlineOrder", job.orderId);
      const attempts = Number(current.attempts || 0) + 1;
      const giveUp = !!error && attempts >= MAX_ATTEMPTS;
      if (fresh?.fulfilment?.shipment) {
        fresh.fulfilment.shipment = error
          ? {
              ...fresh.fulfilment.shipment,
              state: giveUp ? "failed" : "error",
              error,
              attempts,
              nextAt: giveUp ? null : new Date(Date.now() + backoffMs(attempts)).toISOString(),
            }
          : { ...fresh.fulfilment.shipment, state: "sent", error: null, attempts, magentoShipmentId: shipmentId, sentAt: now() };
        if (!error && fresh.fulfilment.status !== "delivered") fresh.fulfilment.status = "shipped";
        await putRecord(tx, org, "onlineOrder", fresh, fresh.branchId);
      }
      if (error && !giveUp)
        await putRecord(tx, org, "magentoShipment", { ...current, attempts, error, nextAt: new Date(Date.now() + backoffMs(attempts)).toISOString() });
      else await tx.query("DELETE FROM records WHERE organization_id=$1 AND kind='magentoShipment' AND id=$2", [org, job.id]);
    });
  }
  return { sent, failed };
}

/** Sends shipments every [intervalMs] in the API process. Returns a stop function. */
export function startShipmentWorker(db: Database, intervalMs = 15_000) {
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await runMagentoShipments(db);
    } catch (error) {
      console.error("Magento shipment error", error);
    } finally {
      running = false;
    }
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}
