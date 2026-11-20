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
    if (order.status !== "open" && order.status !== "partial") continue;
    for (const line of order.lines) {
      const outstanding = Math.max(0, line.quantity - line.received);
      onOrder.set(line.productId, (onOrder.get(line.productId) || 0) + outstanding);
    }
  }
  return products.filter(p => !p.salesStopped && p.type !== "service" && p.reorderLevel > 0 && (available.get(p.id) || 0) <= p.reorderLevel)
    .map(p => {
      const shelf = available.get(p.id) || 0;
      const inbound = onOrder.get(p.id) || 0;
      return { productId: p.id, sku: p.sku, name: p.name, available: shelf,
        reorderLevel: p.reorderLevel, onOrder: inbound, suggestedQuantity: Math.max(0, 2 * p.reorderLevel - shelf - inbound),
        supplierId: p.supplierId };
    });
}
