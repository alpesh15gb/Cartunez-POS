// WS-C (workshop): composite kits / installation packages.
//
// A kit is a catalog item with `components: [{ productId, qty }]` (see
// buildProduct in catalog.ts). It is stored as a non-stock item, so checkout
// does not look for kit stock in a bin.
//
// Design (documented choice): the kit sells as ONE invoice line at the kit's
// own price, HSN and GST rate, so the tax on the invoice is exactly the tax on
// that price. What it is made of is recorded on the line as
// `line.components = [{ productId, sku, name, qty, binId }]` (qty = units for
// the whole line); component parts carry no price of their own and never
// appear as separate taxable lines. At checkout each stocked component leaves
// its bin ("Kit sale" stock movements against the invoice). Labour included in
// a kit is a service component: recorded, no stock movement.
//
// Reservations: a kit on a parked sale (routes/holds.ts) or a job card
// (routes/jobs.ts) reserves its stocked components in bins
// (`line.components` on the hold line, see reserveKitComponents), so counter
// sales cannot take them; checkout of that hold takes the kit's components
// from the reserved bins first. An expired hold reserves nothing.
//
// Limitations: kits cannot contain serial-tracked parts or other kits. A sales
// return of a kit line (returns.ts) puts its stocked components back into the
// chosen restock or damaged bin, in proportion to the kits returned.
import { getRecord, records, type RecordData } from "../db.js";
import { adjust, fail, heldUnits, holdReserves, integer } from "../domain.js";
import { registerSaleHook } from "../sale-pipeline.js";
import type { KitComponent, SaleContext, SaleHook } from "../sale-types.js";

export { isKit, reserveKitComponents } from "./kit-reserve.js";
import { isKit } from "./kit-reserve.js";

/**
 * How many kits the components in stock can make (null = no stocked components,
 * so no stock limit). `stock` rows are { productId, binId, available }.
 */
export function kitAvailability(
  kit: RecordData,
  products: RecordData[],
  stock: { productId: string; binId: string; available: number }[],
  sellableBinIds?: Set<string>,
): number | null {
  let result: number | null = null;
  for (const component of kit.components || []) {
    const product = products.find((entry) => entry.id === component.productId);
    if (!product || product.type === "service") continue;
    const available = stock
      .filter((row) => row.productId === component.productId && (!sellableBinIds || sellableBinIds.has(row.binId)))
      .reduce((sum, row) => sum + Math.max(0, row.available), 0);
    const kits = Math.floor(available / component.qty);
    result = result === null ? kits : Math.min(result, kits);
  }
  return result;
}

async function productFor(ctx: SaleContext, productId: string) {
  return ctx.body.offline
    ? ctx.catalog?.products?.find((entry: any) => entry.id === productId)
    : await getRecord(ctx.db, ctx.actor.organizationId, "product", productId);
}

const kits: SaleHook = {
  name: "ws-c-kits",
  async validateLine(ctx, input, line) {
    const kit = await productFor(ctx, line.productId);
    if (!isKit(kit)) return;
    line.kind = "kit";
    const state = (ctx.state.kits ??= {
      used: new Map<string, number>(),
      bins: (await records(ctx.db, ctx.actor.organizationId, "location", ctx.actor.branchId))
        .filter((bin) => bin.kind === "sellable")
        .map((bin) => bin.id),
    });
    // Units of a part the plain lines of this sale take from a bin.
    const plain = (productId: string, binId: string) =>
      (ctx.body.lines || [])
        .filter((entry: any) => entry.productId === productId && entry.binId === binId)
        .reduce((sum: number, entry: any) => sum + (Number(entry.qty) || 0), 0);
    // What the resumed parked sale (or job card) reserves in a bin, kit components
    // included; an expired hold reserves nothing, so it adds nothing back.
    const ownLines = ctx.hold && holdReserves(ctx.hold) ? ctx.hold.cart?.lines || [] : [];
    const parked = (productId: string, binId: string) => heldUnits(ownLines, productId, binId);
    // Bins this kit's line reserved on the hold come first, so billing uses the reservation.
    const reservedFor = (productId: string, binId: string) =>
      ownLines
        .filter((entry: any) => entry.productId === line.productId)
        .flatMap((entry: any) => entry.components || [])
        .filter((entry: any) => entry.productId === productId && entry.binId === binId)
        .reduce((sum: number, entry: any) => sum + (Number(entry.qty) || 0), 0);
    const components: KitComponent[] = [];
    let unitCost = 0;
    for (const component of kit!.components) {
      const part = await productFor(ctx, component.productId);
      if (!part) fail(`Kit ${kit!.sku} lists an item that is no longer in the catalog. Edit the kit.`, 409);
      if (isKit(part)) fail(`Kit ${kit!.sku} contains another kit. Edit the kit to list its parts directly.`, 409);
      if (part.serialTracked)
        fail(`Kit ${kit!.sku} contains serial-tracked ${part.sku}. Sell that part as its own line.`, 409);
      const qty = integer(component.qty * line.qty, "Kit component quantity", 1, 9999999);
      unitCost += (part.cost || 0) * component.qty;
      if (part.type === "service") {
        components.push({ productId: part.id, sku: part.sku, name: part.name, qty, type: "service" } as KitComponent);
        continue;
      }
      // Take from the fullest sellable bins first.
      const free = (binId: string) =>
        (ctx.stock.find((row: any) => row.productId === part.id && row.binId === binId)?.available || 0) +
        parked(part.id, binId) - plain(part.id, binId) - (state.used.get(part.id + "|" + binId) || 0);
      const order = [...state.bins].sort(
        (a: string, b: string) => reservedFor(part.id, b) - reservedFor(part.id, a) || free(b) - free(a),
      );
      if (!order.length) fail("Add a sellable bin before selling kits.");
      let remaining = qty;
      for (const binId of order) {
        if (remaining <= 0) break;
        const take = Math.min(remaining, Math.max(0, free(binId)));
        if (!take) continue;
        components.push({ productId: part.id, sku: part.sku, name: part.name, qty: take, binId } as KitComponent);
        state.used.set(part.id + "|" + binId, (state.used.get(part.id + "|" + binId) || 0) + take);
        remaining -= take;
      }
      if (remaining > 0) {
        if (!(ctx.reconcile || ctx.sellBeyondStock))
          fail(`Not enough ${part.sku} in stock to make kit ${kit!.sku}.`, 409);
        const binId = components.find((entry) => entry.productId === part.id)?.binId || order[0];
        const existing = components.find((entry) => entry.productId === part.id && entry.binId === binId);
        if (existing) existing.qty += remaining;
        else components.push({ productId: part.id, sku: part.sku, name: part.name, qty: remaining, binId } as KitComponent);
        state.used.set(part.id + "|" + binId, (state.used.get(part.id + "|" + binId) || 0) + remaining);
      }
    }
    line.components = components;
    // Cost of goods for reports: what the components cost (per kit).
    line.cost = unitCost;
    integer(unitCost * line.qty, "Line cost");
  },
  async afterPersist(ctx) {
    for (const line of ctx.lines) {
      if (line.kind !== "kit" || !line.components) continue;
      for (const component of line.components)
        if (component.binId)
          await adjust(ctx.db, ctx.actor, component.productId, component.binId, -component.qty, "Kit sale",
            ctx.invoice!.id, ctx.reconcile || ctx.sellBeyondStock);
    }
  },
};
registerSaleHook(kits);
