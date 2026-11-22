import type { RecordData } from "./db.js";

/** Branch availability already excludes parked carts and online reservations. */
export function reorderSuggestions(products: RecordData[], stock: RecordData[], locations: RecordData[], orders: RecordData[]) {
  const sellable = new Set(locations.filter(bin => bin.kind === "sellable").map(bin => bin.id));
  const available = new Map<string, number>();
  const onOrder = new Map<string, number>();
  for (const row of stock) {
    if (sellable.has(row.binId)) available.set(row.productId, (available.get(row.productId) || 0) + Number(row.available));
  }
  for (const order of orders) {
    // WS-E: draft orders made from these suggestions count as on order, so they are not suggested twice.
    if (order.status !== "open" && order.status !== "partial" && order.status !== "draft") continue;
    for (const line of order.lines) {
      const outstanding = Math.max(0, line.quantity - line.received);
      onOrder.set(line.productId, (onOrder.get(line.productId) || 0) + outstanding);
    }
  }
  // Online-only parts are not shop stock, so they are never reorder alerts.
  return products.filter(p => !p.salesStopped && p.type !== "service" && !p.onlineOnly && p.reorderLevel > 0 && (available.get(p.id) || 0) <= p.reorderLevel)
    .map(p => {
      const shelf = available.get(p.id) || 0;
      const inbound = onOrder.get(p.id) || 0;
      return { productId: p.id, sku: p.sku, name: p.name, available: shelf,
        reorderLevel: p.reorderLevel, onOrder: inbound, suggestedQuantity: Math.max(0, 2 * p.reorderLevel - shelf - inbound),
        supplierId: p.supplierId };
    });
}

/** WS-E: suggestions grouped by each part's usual supplier (parts without one are listed apart). */
export function groupBySupplier<T extends { supplierId?: string | null }>(rows: T[]) {
  const groups = new Map<string, T[]>();
  const noSupplier: T[] = [];
  for (const row of rows) {
    if (!row.supplierId) {
      noSupplier.push(row);
      continue;
    }
    groups.set(row.supplierId, [...(groups.get(row.supplierId) || []), row]);
  }
  return { groups, noSupplier };
}
