// Money and stock review: kit component reservations for parked sales and job
// cards (see hooks/kits.ts). Kept apart from the checkout hook so routes can use
// it without changing the order checkout hooks register in.
import { getRecord, type Database, type RecordData } from "../db.js";
import { type Actor, fail, integer } from "../domain.js";
import type { KitComponent } from "../sale-types.js";

export const isKit = (product: RecordData | undefined) => !!product?.components?.length;

/**
 * The stocked components a kit line reserves on a parked sale or job card:
 * [{ productId, sku, name, qty, binId }], taken from the fullest sellable bins.
 * `free` = what is available in a bin to this document (stock not reserved by
 * others, plus what this document reserved before); `taken` counts what the
 * document's other lines already use, keyed "productId|binId", and is updated.
 */
export async function reserveKitComponents(
  db: Database,
  actor: Actor,
  kit: RecordData,
  qty: number,
  options: {
    free: (productId: string, binId: string) => number;
    taken: Map<string, number>;
    bins: string[];
    sellBeyondStock: boolean;
  },
): Promise<KitComponent[]> {
  const reserved: KitComponent[] = [];
  for (const component of kit.components || []) {
    const part = await getRecord(db, actor.organizationId, "product", component.productId);
    if (!part) fail(`Kit ${kit.sku} lists an item that is no longer in the catalog. Edit the kit.`, 409);
    if (part.onlineOnly) fail("Website-only item " + part.sku + " cannot be used in a counter kit.", 409);
    if (isKit(part)) fail(`Kit ${kit.sku} contains another kit. Edit the kit to list its parts directly.`, 409);
    if (part.type === "service") continue;
    if (!options.bins.length) fail("Add a sellable bin before reserving kits.");
    const left = (binId: string) => options.free(part.id, binId) - (options.taken.get(part.id + "|" + binId) || 0);
    const take = (binId: string, units: number) => {
      const existing = reserved.find((entry) => entry.productId === part.id && entry.binId === binId);
      if (existing) existing.qty += units;
      else reserved.push({ productId: part.id, sku: part.sku, name: part.name, qty: units, binId } as KitComponent);
      options.taken.set(part.id + "|" + binId, (options.taken.get(part.id + "|" + binId) || 0) + units);
    };
    let remaining = integer(component.qty * qty, "Kit component quantity", 1, 9999999);
    for (const binId of [...options.bins].sort((a, b) => left(b) - left(a))) {
      if (remaining <= 0) break;
      const units = Math.min(remaining, Math.max(0, left(binId)));
      if (units) {
        take(binId, units);
        remaining -= units;
      }
    }
    if (remaining > 0) {
      if (!options.sellBeyondStock) fail(`Not enough ${part.sku} in stock to reserve kit ${kit.sku}.`, 409);
      take(reserved.find((entry) => entry.productId === part.id)?.binId || options.bins[0], remaining);
    }
  }
  return reserved;
}
