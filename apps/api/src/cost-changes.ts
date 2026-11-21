// WS-E: vendor cost hikes found while receiving goods (purchase bills and
// purchase-order receipts). A unit cost more than the threshold above the last
// purchase cost is flagged on the line and kept as a "costChange" record with
// the old and new cost and what it does to the margin, until someone updates
// the selling price or dismisses it.
import type { Database, RecordData } from "./db.js";
import { getRecord, putRecord } from "./db.js";
import { type Actor, id, now, roundRatio } from "./domain.js";

/** Default: flag a cost more than 5% above the last purchase cost. */
export const DEFAULT_COST_HIKE_BPS = 500;

export function costHikeThreshold(settings: RecordData | undefined) {
  const value = Number(settings?.purchasing?.costHikeThreshold);
  return Number.isSafeInteger(value) && value >= 0 ? value : DEFAULT_COST_HIKE_BPS;
}

/** The price before GST, which is what the margin is worked out on. */
export function netPrice(price: number, taxRate: number, taxMode: string) {
  return taxMode === "inclusive" ? roundRatio(price, 10000, 10000 + (taxRate || 0)) : price;
}

/** Margin in basis points of the price before GST, or null without a price. */
export function margin(net: number, cost: number) {
  return net > 0 ? roundRatio(net - cost, 10000, net) : null;
}

/** The price that keeps the old margin, rounded up to the next rupee. */
export function priceKeepingMargin(price: number, oldCost: number, newCost: number) {
  if (!price || !oldCost) return price;
  const scaled = roundRatio(price, newCost, oldCost);
  return Math.ceil(scaled / 100) * 100;
}

/** The cost a new unit cost is compared with: the last purchase cost, else the catalogue cost. */
export const previousCost = (product: RecordData) => Number(product.lastPurchaseCost ?? product.cost ?? 0);

/**
 * Compares [newCost] with the part's previous cost, remembers it as the last
 * purchase cost on [product] (the caller saves the product) and records a
 * cost change when it rose by more than the threshold. Returns the hike or null.
 */
export async function noteCost(
  db: Database,
  actor: Actor,
  product: RecordData,
  newCost: number,
  source: { kind: "bill" | "receipt"; id: string; label: string; supplierId: string },
) {
  const settings = await getRecord(db, actor.organizationId, "settings", "settings");
  const oldCost = previousCost(product);
  product.lastPurchaseCost = newCost;
  if (oldCost <= 0 || newCost <= oldCost) return null;
  const increase = roundRatio(newCost - oldCost, 10000, oldCost);
  if (increase <= costHikeThreshold(settings)) return null;
  const price = Number(product.retailPrice || 0);
  const net = netPrice(price, product.taxRate || 0, settings?.taxMode || "exclusive");
  const change = {
    id: id("costchange"),
    branchId: actor.branchId,
    productId: product.id,
    sku: product.sku,
    name: product.name,
    supplierId: source.supplierId,
    source: source.kind,
    sourceId: source.id,
    sourceLabel: source.label,
    oldCost,
    newCost,
    increase,
    retailPrice: price,
    oldMargin: margin(net, oldCost),
    newMargin: margin(net, newCost),
    suggestedPrice: priceKeepingMargin(price, oldCost, newCost),
    status: "open",
    createdAt: now(),
    userId: actor.id,
  };
  await putRecord(db, actor.organizationId, "costChange", change, actor.branchId);
  return {
    costChangeId: change.id,
    oldCost,
    newCost,
    increase,
    oldMargin: change.oldMargin,
    newMargin: change.newMargin,
    suggestedPrice: change.suggestedPrice,
  };
}
