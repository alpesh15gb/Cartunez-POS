// Daily comparison of Magento with the POS. Reads each published part back
// from Magento; anything that drifted (stock, price, status, a deleted
// product) is queued to be sent again, and the result is kept for the screen.
import type { FastifyInstance } from "fastify";
import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { allow, fail, type Actor } from "./domain.js";
import { magentoConfig, queueMagentoSync } from "./online-queue.js";
import { MagentoError, magentoRequest, onSaleNow, onlinePrices, onlineQuantity } from "./magento.js";

type Fetch = typeof globalThis.fetch;
const DAY = 24 * 3600_000;

const special = (mg: any) =>
  Number((mg?.custom_attributes || []).find((a: any) => a.attribute_code === "special_price")?.value ?? NaN);

/**
 * Re-queues parts Magento still shows in the Sale category although their sale
 * has ended (end date passed, unpublished), so the next sync drops the link.
 * Returns the product IDs queued.
 */
export async function queueEndedSales(db: Database, organizationId: string, now = new Date()) {
  const ended = (await records(db, organizationId, "onlineListing"))
    .filter((l) => l.sync?.onSale && l.sync?.state !== "pending" && !onSaleNow(l, now))
    .map((l) => l.productId);
  if (ended.length) await db.transaction((tx) => queueMagentoSync(tx, organizationId, ended, "sale ended"));
  return ended;
}

/** Compares Magento with the POS for one shop (or all) and queues fixes. */
export async function compareMagento(db: Database, options: { fetch?: Fetch; organizationId?: string } = {}) {
  const fetchImpl = options.fetch || globalThis.fetch;
  const orgs = options.organizationId
    ? [options.organizationId]
    : (await db.query("SELECT organization_id FROM records WHERE kind='settings'")).rows.map((r: any) => r.organization_id);
  const results = [];
  for (const org of orgs) {
    const settings = await getRecord(db, org, "settings", "settings");
    const config = magentoConfig(settings);
    const secret = await getRecord(db, org, "integrationSecret", "magento");
    if (!config.enabled || !config.baseUrl || !secret?.token) continue;
    await queueEndedSales(db, org);
    const listings = (await records(db, org, "onlineListing")).filter((l) => l.published || l.sync?.magentoId).slice(0, 2000);
    const differences: any[] = [];
    let checked = 0;
    let error: string | null = null;
    for (const listing of listings) {
      const product = await getRecord(db, org, "product", listing.productId);
      if (!product) continue;
      if (listing.sync?.state === "pending") continue; // already on its way
      const sku = listing.sync?.magentoSku || product.sku;
      const prices = onlinePrices(product, settings, listing);
      const qty = await onlineQuantity(db, org, config.branchId, product.id, listing.buffer ?? config.defaultBuffer ?? 0);
      let mg: any;
      try {
        mg = await magentoRequest(fetchImpl, config.baseUrl, secret.token, "GET", `/all/V1/products/${encodeURIComponent(sku)}`);
      } catch (e: any) {
        if (e instanceof MagentoError && /doesn't exist|not found|requested doesn't/i.test(e.message)) {
          if (listing.published) differences.push({ productId: product.id, sku, field: "product", pos: "published", magento: "missing" });
          checked++;
          continue;
        }
        error = e instanceof MagentoError ? e.message : String(e?.message || e);
        break;
      }
      checked++;
      const found: [string, unknown, unknown][] = [];
      const status = listing.published ? 1 : 2;
      if (Number(mg.status) !== status) found.push(["status", status === 1 ? "enabled" : "disabled", Number(mg.status) === 1 ? "enabled" : "disabled"]);
      if (listing.published) {
        const stockItem = mg.extension_attributes?.stock_item;
        if (product.onlineOnly) {
          // Online only: stock is not managed on the website (always sellable).
          if (stockItem && stockItem.manage_stock !== false && stockItem.manage_stock !== 0)
            found.push(["stock", "not managed", "managed"]);
        } else {
          const mgQty = Number(stockItem?.qty ?? NaN);
          if (mgQty !== qty) found.push(["qty", qty, Number.isNaN(mgQty) ? null : mgQty]);
        }
        if (Math.abs(Number(mg.price) - prices.mrp / 100) > 0.005) found.push(["mrp", prices.mrp / 100, Number(mg.price)]);
        const sp = special(mg);
        if (Number.isNaN(sp) || Math.abs(sp - prices.selling / 100) > 0.005) found.push(["price", prices.selling / 100, Number.isNaN(sp) ? null : sp]);
      }
      for (const [field, pos, magento] of found) differences.push({ productId: product.id, sku, field, pos, magento });
    }
    const productIds = [...new Set(differences.map((d) => d.productId))];
    await db.transaction(async (tx) => {
      if (productIds.length) await queueMagentoSync(tx, org, productIds, "check");
      await putRecord(tx, org, "magentoCheck", {
        id: "latest",
        at: new Date().toISOString(),
        checked,
        differences: differences.slice(0, 100),
        differenceCount: differences.length,
        partsFixed: productIds.length,
        error,
      });
    });
    results.push({ organizationId: org, checked, differences: differences.length, error });
  }
  return results;
}

/** Runs the comparison once a day (checked every 15 minutes). Returns a stop function. */
export function startDailyMagentoCheck(db: Database, intervalMs = 15 * 60_000) {
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try {
      const orgs = (await db.query("SELECT organization_id FROM records WHERE kind='settings'")).rows.map((r: any) => r.organization_id);
      for (const org of orgs) {
        // Sales that ended leave the shop's Sale page without waiting for the daily check.
        if (magentoConfig(await getRecord(db, org, "settings", "settings")).enabled) await queueEndedSales(db, org);
        const last = await getRecord(db, org, "magentoCheck", "latest");
        if (!last || Date.now() - Date.parse(last.at) > DAY) await compareMagento(db, { organizationId: org });
      }
    } catch (error) {
      console.error("Magento comparison error", error);
    } finally {
      running = false;
    }
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

export function magentoCheckRoutes(app: FastifyInstance, db: Database, fetchImpl: () => Fetch) {
  app.post("/api/v1/integrations/magento/compare", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager"]);
    const [result] = await compareMagento(db, { fetch: fetchImpl(), organizationId: actor.organizationId });
    if (!result) fail("Magento is not connected.", 409);
    if (result.error) fail(result.error, 502);
    return result;
  });
}
