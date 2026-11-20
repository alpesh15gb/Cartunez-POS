// Magento orders → POS. Orders are read from Magento every minute. Each item's
// stock is reserved in the online branch, taken out of the bins when Magento
// invoices it and released when it is cancelled. Staff inspect physical returns.
// Everything is worked out from Magento's per-item quantities, so reading the
// same order again never counts it twice.
import type { FastifyInstance } from "fastify";
import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { adjust, allow, fail, id, type Actor } from "./domain.js";
import { magentoConfig } from "./online-queue.js";
import { magentoRequest, MagentoError } from "./magento.js";

type Fetch = typeof globalThis.fetch;
type Post = (
  path: string,
  handler: (db: Database, actor: Actor, body: any, params: any) => Promise<any>,
) => unknown;

const paise = (v: unknown) => Math.round(Number(v || 0) * 100);
const magentoDate = (iso: string) => iso.slice(0, 19).replace("T", " ");
const isoDate = (magento: string | undefined) => (magento ? magento.replace(" ", "T") + "Z" : new Date().toISOString());

/** The POS acts as "Magento" when it moves stock for online orders. */
function systemActor(organizationId: string, branchId: string): Actor {
  return { id: "magento", name: "Magento", role: "owner", organizationId, branchId };
}

/** What a Magento order item asks of the POS: units to hold, and units sold. */
export function itemTargets(item: any, previous: any = {}) {
  const ordered = Number(item.qty_ordered || 0);
  const invoiced = Number(item.qty_invoiced || 0);
  const canceled = Number(item.qty_canceled || 0);
  const refunded = Number(item.qty_refunded || 0);
  // Older registers already put refunded units back. Preserve that historical
  // movement when the same order is first read after an upgrade.
  const priorReturnCredit = previous.priorReturnCredit ?? Math.max(0, Number(previous.invoiced || 0) - Number(previous.sold || 0));
  return {
    priorReturnCredit,
    ordered,
    invoiced,
    canceled,
    refunded,
    reserve: Math.max(0, ordered - invoiced - canceled),
    // A refund releases outstanding demand. A part already taken from a bin
    // stays out until staff inspect it and record its physical return.
    sold: Math.max(
      Number(previous.deducted || 0),
      Number(previous.sold || 0) + invoiced - Number(previous.invoiced || 0) - refunded + Number(previous.refunded || 0),
      Math.max(0, Number(item.qty_shipped || 0) - priorReturnCredit),
    ),
  };
}

/** Units per product held for open online orders in [branchId]. */
export async function onlineReservations(db: Database, organizationId: string, branchId: string) {
  const held = new Map<string, number>();
  for (const order of await records(db, organizationId, "onlineOrder", branchId)) {
    for (const line of order.lines || []) {
      if (!line.productId) continue;
      const units = Number(line.reserved || 0) + Number(line.awaiting || 0);
      if (units > 0) held.set(line.productId, (held.get(line.productId) || 0) + units);
    }
  }
  return held;
}

/** Stock in each sellable bin of the branch, after parked sales. */
async function binStock(db: Database, actor: Actor, productId: string) {
  const bins = (await records(db, actor.organizationId, "location", actor.branchId)).filter((b) => b.kind === "sellable");
  const rows = (
    await db.query(
      "SELECT bin_id, quantity FROM stock WHERE organization_id=$1 AND branch_id=$2 AND product_id=$3",
      [actor.organizationId, actor.branchId, productId],
    )
  ).rows as { bin_id: string; quantity: number }[];
  const holds = await records(db, actor.organizationId, "hold", actor.branchId);
  return bins
    .map((bin) => {
      const onHand = Number(rows.find((r) => r.bin_id === bin.id)?.quantity || 0);
      const parked = holds.reduce(
        (sum, hold) =>
          sum +
          (hold.cart?.lines || [])
            .filter((l: any) => l.productId === productId && l.binId === bin.id)
            .reduce((s: number, l: any) => s + Number(l.qty || 0), 0),
        0,
      );
      return { binId: bin.id as string, available: onHand - parked };
    })
    .filter((b) => b.available > 0)
    .sort((a, b) => b.available - a.available);
}

/** Brings the POS stock in line with the order's Magento quantities. */
export async function applyOnlineOrder(db: Database, order: any, branchId: string) {
  const actor = systemActor(order.organizationId, branchId);
  for (const line of order.lines) {
    line.moves ||= [];
    line.deducted ||= 0;
    if (!line.productId) {
      line.reserved = 0;
      line.awaiting = 0;
      continue;
    }
    const want = Number(line.sold || 0);
    // Invoiced: take the units out of the bins with the most stock.
    const product = await getRecord(db, order.organizationId, "product", line.productId);
    line.serialPickRequired = !!product?.serialTracked && want > line.deducted;
    if (want > line.deducted && !line.serialPickRequired) {
      let need = want - line.deducted;
      for (const bin of await binStock(db, actor, line.productId)) {
        if (need <= 0) break;
        const take = Math.min(need, bin.available);
        await adjust(db, actor, line.productId, bin.binId, -take, `Online order #${order.number}`, order.id);
        line.moves.push({ binId: bin.binId, qty: take });
        line.deducted += take;
        need -= take;
      }
    }
    line.awaiting = Math.max(0, want - line.deducted);
    line.reserved = Number(line.reserve || 0);
  }
  // Shortage: units this order still needs that the branch does not have.
  const held = await onlineReservations(db, order.organizationId, branchId);
  for (const line of order.lines) {
    if (!line.productId) continue;
    const otherOrders = (held.get(line.productId) || 0) - (order.previousHeld?.[line.productId] || 0);
    const available = (await binStock(db, actor, line.productId)).reduce((s, b) => s + b.available, 0);
    const mine = line.reserved + line.awaiting;
    line.shortage = Math.max(0, mine - Math.max(0, available - Math.max(0, otherOrders)));
  }
  delete order.previousHeld;
  order.posState = orderState(order);
  return order;
}

export function orderState(order: any) {
  const lines = (order.lines || []).filter((l: any) => l.productId);
  if (lines.some((l: any) => l.awaiting > 0)) return "awaiting";
  if (lines.some((l: any) => l.reserved > 0)) return "reserved";
  const ordered = lines.reduce((s: number, l: any) => s + l.ordered, 0);
  const canceled = lines.reduce((s: number, l: any) => s + l.canceled, 0);
  const refunded = lines.reduce((s: number, l: any) => s + l.refunded, 0);
  if (ordered > 0 && canceled >= ordered) return "cancelled";
  if (refunded > 0 && lines.every((l: any) => l.refunded + l.canceled >= l.ordered)) return "refunded";
  if (!lines.length) return "unmatched";
  return "sold";
}

/** Turns a Magento order into the POS record and applies it, in one transaction. */
export async function importMagentoOrder(db: Database, organizationId: string, branchId: string, mg: any) {
  return db.transaction(async (tx) => {
    const recordId = `mg-${mg.entity_id}`;
    const existing = await getRecord(tx, organizationId, "onlineOrder", recordId);
    if (existing && existing.updatedAt > isoDate(mg.updated_at)) return existing;
    // An existing order's stock movements belong to its original fulfilment branch.
    branchId = existing?.branchId ?? branchId;
    const products = await records(tx, organizationId, "product");
    const address = mg.extension_attributes?.shipping_assignments?.[0]?.shipping?.address || mg.billing_address || {};
    const items = (mg.items || []).filter((item: any) => !item.parent_item_id);
    const previousHeld: Record<string, number> = {};
    for (const line of existing?.lines || []) {
      if (line.productId) previousHeld[line.productId] = (previousHeld[line.productId] || 0) + (line.reserved || 0) + (line.awaiting || 0);
    }
    const order: any = {
      ...(existing || {}),
      id: recordId,
      organizationId,
      branchId,
      magentoId: mg.entity_id,
      number: String(mg.increment_id || mg.entity_id),
      state: mg.state || "",
      status: mg.status || "",
      customer: {
        name: [mg.customer_firstname, mg.customer_lastname].filter(Boolean).join(" ") || [address.firstname, address.lastname].filter(Boolean).join(" ") || "Guest",
        email: mg.customer_email || "",
        phone: address.telephone || "",
      },
      shipTo: [...(address.street || []), address.city, address.postcode].filter(Boolean).join(", "),
      total: paise(mg.grand_total),
      currency: mg.order_currency_code || mg.base_currency_code || "INR",
      createdAt: isoDate(mg.created_at),
      updatedAt: isoDate(mg.updated_at),
      importedAt: existing?.importedAt || new Date().toISOString(),
      previousHeld,
      lines: items.map((item: any) => {
        const before = (existing?.lines || []).find((l: any) => l.itemId === item.item_id) || {};
        const product = products.find((p) => p.sku === item.sku);
        const t = itemTargets(item, before);
        return {
          ...before,
          itemId: item.item_id,
          sku: item.sku,
          name: item.name,
          productId: before.productId || product?.id || null,
          price: paise(item.price_incl_tax ?? item.price),
          ordered: t.ordered,
          invoiced: t.invoiced,
          canceled: t.canceled,
          refunded: t.refunded,
          reserve: t.reserve,
          sold: t.sold,
          priorReturnCredit: t.priorReturnCredit,
        };
      }),
    };
    await applyOnlineOrder(tx, order, branchId);
    return putRecord(tx, organizationId, "onlineOrder", order, branchId);
  });
}

/** Re-applies orders still waiting for stock (after goods arrive). */
async function retryAwaiting(db: Database, organizationId: string, branchId: string) {
  for (const order of await records(db, organizationId, "onlineOrder", branchId)) {
    if (order.posState !== "awaiting" && !(order.lines || []).some((l: any) => l.shortage > 0)) continue;
    await db.transaction(async (tx) => {
      const fresh = await getRecord(tx, organizationId, "onlineOrder", order.id);
      if (!fresh) return;
      fresh.previousHeld = Object.fromEntries(
        (fresh.lines || []).filter((l: any) => l.productId).map((l: any) => [l.productId, (l.reserved || 0) + (l.awaiting || 0)]),
      );
      await applyOnlineOrder(tx, fresh, branchId);
      await putRecord(tx, organizationId, "onlineOrder", fresh, branchId);
    });
  }
}

/** Reads new and changed orders from Magento (all shops, or one). Network calls run outside transactions. */
export async function pollMagentoOrders(db: Database, options: { fetch?: Fetch; organizationId?: string } = {}) {
  const fetchImpl = options.fetch || globalThis.fetch;
  const orgs = options.organizationId
    ? [options.organizationId]
    : (await db.query("SELECT organization_id FROM records WHERE kind='settings'")).rows.map((r: any) => r.organization_id);
  let imported = 0;
  for (const org of orgs) {
    const settings = await getRecord(db, org, "settings", "settings");
    const config = magentoConfig(settings);
    const secret = await getRecord(db, org, "integrationSecret", "magento");
    if (!config.enabled || !config.baseUrl || !secret?.token || !config.branchId) continue;
    const cursor = (await getRecord(db, org, "magentoCursor", "orders")) || {
      id: "orders",
      since: config.connectedAt || new Date(Date.now() - 3600_000).toISOString(),
    };
    let since = cursor.since as string;
    let error: string | null = null;
    try {
      for (let page = 1; ; page++) {
        const q = new URLSearchParams({
          "searchCriteria[filter_groups][0][filters][0][field]": "updated_at",
          "searchCriteria[filter_groups][0][filters][0][value]": magentoDate(cursor.since),
          "searchCriteria[filter_groups][0][filters][0][condition_type]": "gteq",
          "searchCriteria[sortOrders][0][field]": "updated_at",
          "searchCriteria[sortOrders][0][direction]": "ASC",
          "searchCriteria[sortOrders][1][field]": "entity_id",
          "searchCriteria[sortOrders][1][direction]": "ASC",
          "searchCriteria[pageSize]": "50",
          "searchCriteria[currentPage]": String(page),
        });
        const result = await magentoRequest(fetchImpl, config.baseUrl, secret.token, "GET", `/all/V1/orders?${q}`);
        const items: any[] = result?.items || [];
        for (const mg of items) {
          await importMagentoOrder(db, org, config.branchId, mg);
          imported++;
          const at = isoDate(mg.updated_at);
          if (at > since) since = at;
        }
        if (items.length < 50 || page * 50 >= Number(result.total_count)) break;
      }
    } catch (e: any) {
      error = e instanceof MagentoError ? e.message : String(e?.message || e);
    }
    await retryAwaiting(db, org, config.branchId);
    await putRecord(db, org, "magentoCursor", { ...cursor, since, checkedAt: new Date().toISOString(), error });
  }
  return { imported };
}

export function magentoOrderRoutes(app: FastifyInstance, db: Database, post: Post, fetchImpl: () => Fetch) {
  // "Check now" on the Online orders screen.
  app.post("/api/v1/integrations/magento/orders/poll", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager"]);
    const result = await pollMagentoOrders(db, { fetch: fetchImpl(), organizationId: actor.organizationId });
    const cursor = await getRecord(db, actor.organizationId, "magentoCursor", "orders");
    if (cursor?.error) fail(cursor.error, 502);
    return { ...result, checkedAt: cursor?.checkedAt };
  });

  // Take stock that has arrived for an order waiting for it.
  post("online-orders/:id/fulfil", async (tx, actor, _body, params) => {
    allow(actor, ["owner", "manager"]);
    const order = await getRecord(tx, actor.organizationId, "onlineOrder", String(params.id));
    if (!order) fail("Online order not found.", 404);
    order!.previousHeld = Object.fromEntries(
      (order!.lines || []).filter((l: any) => l.productId).map((l: any) => [l.productId, (l.reserved || 0) + (l.awaiting || 0)]),
    );
    if (order!.branchId !== actor.branchId) fail("Switch to the fulfilment branch for this order.", 409);
    await applyOnlineOrder(tx, order, order!.branchId);
    return putRecord(tx, actor.organizationId, "onlineOrder", order!, order!.branchId);
  });

  // Purchase orders for the parts an online order is short of, one per supplier.
  post("online-orders/:id/purchase-order", async (tx, actor, _body, params) => {
    allow(actor, ["owner", "manager"]);
    const order = await getRecord(tx, actor.organizationId, "onlineOrder", String(params.id));
    if (!order) fail("Online order not found.", 404);
    if (order!.branchId !== actor.branchId) fail("Switch to the online branch to order parts for this order.", 409);
    const outstanding = new Map<string, number>();
    for (const poId of order!.purchaseOrderIds || []) {
      const po = await getRecord(tx, actor.organizationId, "purchaseOrder", poId);
      for (const line of po?.lines || []) {
        outstanding.set(line.productId, (outstanding.get(line.productId) || 0) + line.quantity - line.received);
      }
    }
    const bySupplier = new Map<string, any[]>();
    for (const line of order!.lines || []) {
      if (!line.productId || !(line.shortage > 0)) continue;
      const onOrder = outstanding.get(line.productId) || 0;
      const quantity = Math.max(0, line.shortage - onOrder);
      outstanding.set(line.productId, Math.max(0, onOrder - line.shortage));
      if (!quantity) continue;
      const product = await getRecord(tx, actor.organizationId, "product", line.productId);
      if (!product?.supplierId) fail(`${product?.name || line.sku} has no supplier. Add one to the part first.`);
      const lines = bySupplier.get(product!.supplierId) || [];
      const samePart = lines.find((item) => item.productId === product!.id);
      if (samePart) samePart.quantity += quantity;
      else lines.push({ productId: product!.id, quantity, cost: Number(product!.cost || 0), received: 0 });
      bySupplier.set(product!.supplierId, lines);
    }
    if (!bySupplier.size) fail("All missing units are already on order or in stock.", 409);
    const created = [];
    for (const [supplierId, lines] of bySupplier) {
      const po = {
        id: id("po"),
        branchId: actor.branchId,
        supplierId,
        lines,
        status: "open",
        createdAt: new Date().toISOString(),
        userId: actor.id,
        note: `For online order #${order!.number}`,
        onlineOrderId: order!.id,
      };
      await putRecord(tx, actor.organizationId, "purchaseOrder", po, actor.branchId);
      created.push(po.id);
    }
    order!.purchaseOrderIds = [...(order!.purchaseOrderIds || []), ...created];
    await putRecord(tx, actor.organizationId, "onlineOrder", order!, order!.branchId);
    return { purchaseOrderIds: created };
  });
}

/** Reads Magento orders every [intervalMs] in the API process. Returns a stop function. */
export function startOrderPolling(db: Database, intervalMs = 60_000) {
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await pollMagentoOrders(db);
    } catch (error) {
      console.error("Magento order poll error", error);
    } finally {
      running = false;
    }
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}
