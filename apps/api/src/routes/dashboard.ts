// WS-F: Owner command center. One read-only aggregate the owner's dashboard
// polls every 30-60 s: tills, today's sales and margin by hour, stock alerts,
// online orders waiting, customer dues, shift variances and top items.
// It only reads invoices, returns, shifts and stock; it never writes.
import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import { getRecord, records } from "../db.js";
import { type Actor, allow, fail, inventory, now } from "../domain.js";
import { partyBalances } from "../purchasing.js";
import { reorderSuggestions } from "../replenishment.js";
import { shiftCashSummaries } from "../shift-cash.js";

/** Business time zone used by reports: IST for INR shops, otherwise UTC. */
export function businessZone(settings: any) {
  return settings?.currency === "INR" ? "Asia/Kolkata" : "UTC";
}

function zoned(timeZone: string) {
  const day = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
  const hour = new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", hourCycle: "h23" });
  return {
    day: (date: string | Date) => day.format(new Date(date)),
    hour: (date: string | Date) => Number(hour.format(new Date(date))) % 24,
  };
}

const lineMargin = (line: any) => line.total - line.tax - (line.cost + (line.coreCharge || 0)) * line.qty;

export async function dashboard(db: Database, actor: Actor, query: any = {}) {
  allow(actor, ["owner", "manager"]);
  const deadDays = query.deadDays === undefined ? 90 : Number(query.deadDays);
  if (!Number.isInteger(deadDays) || deadDays < 7 || deadDays > 730)
    fail("Choose between 7 and 730 days for dead stock.");
  const org = actor.organizationId, branch = actor.branchId;
  const settings = await getRecord(db, org, "settings", "settings");
  const timeZone = businessZone(settings);
  const at = query.at && !Number.isNaN(Date.parse(query.at)) ? new Date(query.at) : new Date();
  const z = zoned(timeZone);
  const today = z.day(at);

  const invoices = await records(db, org, "invoice", branch);
  const returns = await records(db, org, "return", branch);
  const shifts = await records(db, org, "shift", branch);
  const products = await records(db, org, "product");
  const users = new Map((await records(db, org, "user")).map((u) => [u.id, u.name]));
  const devices = new Map((await records(db, org, "device", branch)).map((d) => [d.id, d.name]));
  const byProduct = new Map(products.map((p) => [p.id, p]));

  // ---- Today: sales vs margin by hour, top items ----
  const hourly = Array.from({ length: 24 }, (_, hour) => ({ hour, sales: 0, net: 0, margin: 0 }));
  const totals = { sales: 0, gross: 0, returns: 0, net: 0, tax: 0, margin: 0 };
  const items = new Map<string, { productId: string; sku: string; name: string; quantity: number; revenue: number; margin: number }>();
  const item = (line: any) => {
    let row = items.get(line.productId);
    if (!row) items.set(line.productId, row = { productId: line.productId, sku: line.sku, name: line.name, quantity: 0, revenue: 0, margin: 0 });
    return row;
  };
  for (const sale of invoices) {
    if (z.day(sale.createdAt) !== today) continue;
    const bucket = hourly[z.hour(sale.createdAt)];
    const gross = sale.lines.reduce((n: number, l: any) => n + l.total, 0);
    const margin = sale.lines.reduce((n: number, l: any) => n + lineMargin(l), 0);
    bucket.sales++;
    bucket.net += gross;
    bucket.margin += margin;
    totals.sales++;
    totals.gross += gross;
    totals.tax += sale.lines.reduce((n: number, l: any) => n + l.tax, 0);
    totals.margin += margin;
    for (const line of sale.lines) {
      const row = item(line);
      row.quantity += line.qty;
      row.revenue += line.total;
      row.margin += lineMargin(line);
    }
  }
  for (const credit of returns) {
    if (z.day(credit.createdAt) !== today) continue;
    const bucket = hourly[z.hour(credit.createdAt)];
    for (const line of credit.lines) {
      const margin = line.total - line.tax - line.cost;
      bucket.net -= line.total;
      bucket.margin -= margin;
      totals.returns += line.total;
      totals.tax -= line.tax;
      totals.margin -= margin;
      const row = item(line);
      row.quantity -= line.quantity;
      row.revenue -= line.total;
      row.margin -= margin;
    }
  }
  totals.net = totals.gross - totals.returns;
  const topItems = [...items.values()].filter((r) => r.revenue > 0)
    .sort((a, b) => b.revenue - a.revenue || a.sku.localeCompare(b.sku)).slice(0, 5);

  // ---- Till watch: every open shift with the cash that should be in it ----
  const open = shifts.filter((s) => !s.closedAt);
  const lastSale = new Map<string, any>();
  for (const sale of invoices) {
    const seen = lastSale.get(sale.shiftId);
    if (!seen || sale.createdAt > seen.createdAt) lastSale.set(sale.shiftId, sale);
  }
  const tills = (await shiftCashSummaries(db, actor, open)).map((s: any) => {
    const last = lastSale.get(s.id);
    const deviceId = last?.deviceId || null;
    return {
      shiftId: s.id,
      userId: s.userId,
      userName: users.get(s.userId) || s.userId,
      counter: (deviceId && devices.get(deviceId)) || users.get(s.userId) || s.userId,
      deviceId,
      openedAt: s.openedAt,
      openingCash: s.openingCash,
      cashSales: s.cashSales,
      cashRefunds: s.cashRefunds,
      cashIn: s.cashIn,
      cashOut: s.cashOut,
      cashOnHand: s.expectedCash,
      sales: invoices.filter((i) => i.shiftId === s.id).length,
      lastSaleAt: last?.createdAt || null,
    };
  }).sort((a, b) => a.openedAt.localeCompare(b.openedAt));

  // ---- Shift variance flags: closed in the last 7 days and not balanced ----
  const weekAgo = new Date(at.getTime() - 7 * 86400000).toISOString();
  const varianceShifts = shifts
    .filter((s) => s.closedAt && s.closedAt >= weekAgo && Number(s.variance || 0) !== 0)
    .map((s) => ({ shiftId: s.id, userId: s.userId, userName: users.get(s.userId) || s.userId,
      closedAt: s.closedAt, expectedCash: s.expectedCash, countedCash: s.countedCash, variance: s.variance }))
    .sort((a, b) => Math.abs(b.variance) - Math.abs(a.variance) || b.closedAt.localeCompare(a.closedAt));

  // ---- Stock: low and dead ----
  const stock = await inventory(db, actor);
  const locations = await records(db, org, "location", branch);
  const orders = await records(db, org, "purchaseOrder", branch);
  const low = reorderSuggestions(products, stock, locations, orders)
    .sort((a, b) => a.available - b.available || a.sku.localeCompare(b.sku));
  const onHand = new Map<string, number>();
  for (const row of stock) onHand.set(row.productId, (onHand.get(row.productId) || 0) + row.quantity);
  const lastSold = new Map<string, string>();
  for (const sale of invoices)
    for (const line of sale.lines)
      if ((lastSold.get(line.productId) || "") < sale.createdAt) lastSold.set(line.productId, sale.createdAt);
  const firstIn = new Map<string, string>();
  for (const row of (await db.query(
    "SELECT product_id, MIN(created_at) AS first FROM stock_ledger WHERE organization_id=$1 AND branch_id=$2 AND quantity>0 GROUP BY product_id",
    [org, branch])).rows)
    firstIn.set(row.product_id, new Date(row.first).toISOString());
  const cutoff = new Date(at.getTime() - deadDays * 86400000).toISOString();
  const dead = [...onHand.entries()]
    .map(([productId, quantity]) => ({ product: byProduct.get(productId), productId, quantity }))
    .filter(({ product, productId, quantity }) => product && product.type !== "service" && quantity > 0 &&
      (lastSold.get(productId) || "") < cutoff && (firstIn.get(productId) || "") < cutoff)
    .map(({ product, productId, quantity }) => ({
      productId, sku: product!.sku, name: product!.name, quantity,
      value: quantity * Number(product!.cost || 0), lastSoldAt: lastSold.get(productId) || null,
    }))
    .sort((a, b) => b.value - a.value || a.sku.localeCompare(b.sku));

  // ---- Online orders still to pick, invoice or ship ----
  const pendingOrders = (await records(db, org, "onlineOrder", branch))
    .filter((o) => ["awaiting", "reserved"].includes(o.posState) && !o.invoiceId && !o.shippedAt)
    .sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));

  // ---- Customer dues (udhaar) ----
  const customers = new Map((await records(db, org, "customer")).map((c) => [c.id, c.name]));
  const dues = Object.entries(await partyBalances(db, org, "customer"))
    .filter(([, balance]) => balance > 0)
    .map(([customerId, balance]) => ({ customerId, name: customers.get(customerId) || customerId, balance }))
    .sort((a, b) => b.balance - a.balance);

  const conflicts = (await records(db, org, "conflict", branch)).filter((c) => c.status === "pending").length;
  return {
    branchId: branch,
    currency: settings?.currency || "INR",
    timeZone,
    day: today,
    generatedAt: now(),
    today: totals,
    hourly,
    tills,
    lowStock: { count: low.length, rows: low.slice(0, 8) },
    deadStock: { days: deadDays, count: dead.length, value: dead.reduce((n, r) => n + r.value, 0), rows: dead.slice(0, 8) },
    onlineOrders: {
      pending: pendingOrders.length,
      awaitingStock: pendingOrders.filter((o) => o.posState === "awaiting").length,
      value: pendingOrders.reduce((n, o) => n + Number(o.total || 0), 0),
      rows: pendingOrders.slice(0, 5).map((o) => ({ id: o.id, number: o.number, customer: o.customer?.name || "",
        total: o.total, state: o.posState, createdAt: o.createdAt })),
    },
    customerDues: { total: dues.reduce((n, d) => n + d.balance, 0), customers: dues.length, rows: dues.slice(0, 5) },
    varianceShifts: varianceShifts.slice(0, 8),
    topItems,
    pendingConflicts: conflicts,
  };
}

export function dashboardRoutes(app: FastifyInstance, db: Database) {
  app.get("/api/v1/dashboard", async (request: any) =>
    db.readSnapshot((snapshot) => dashboard(snapshot, request.actor, request.query ?? {})));
}
