// Queues products for the Magento sync worker. Called inside the request's
// transaction, so a sale and its "update Magento" job commit together.
// Only depends on db.ts so stock code can import it without cycles.
import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";

export function magentoConfig(settings: any) {
  return settings?.integrations?.magento || {};
}

/**
 * Marks [productIds] for a Magento update. Skips products that were never
 * published, and stock changes in branches that do not sell online.
 */
export async function queueMagentoSync(
  db: Database,
  organizationId: string,
  productIds: Iterable<string>,
  reason: string,
  branchId?: string,
) {
  const settings = await getRecord(db, organizationId, "settings", "settings");
  const config = magentoConfig(settings);
  if (!config.enabled) return;
  if (branchId !== undefined && branchId !== config.branchId) return;
  const at = new Date().toISOString();
  for (const productId of new Set(productIds)) {
    const listing = await getRecord(db, organizationId, "onlineListing", productId);
    if (!listing) continue;
    const currentJob = await getRecord(db, organizationId, "magentoJob", productId);
    if (!listing.published && !listing.sync?.magentoId && !currentJob) continue;
    const job = currentJob || {
      id: productId,
      productId,
      version: 0,
    };
    await putRecord(db, organizationId, "magentoJob", {
      ...job,
      version: (job.version || 0) + 1,
      reason,
      attempts: 0,
      nextAt: at,
      error: null,
      queuedAt: at,
    });
    await putRecord(db, organizationId, "onlineListing", {
      ...listing,
      sync: { ...(listing.sync || {}), state: "pending" },
    });
  }
}

/** Queues every listing that is or was on Magento (after connecting or changing branch). */
export async function queueAllListings(db: Database, organizationId: string, reason: string) {
  const listings = await records(db, organizationId, "onlineListing");
  await queueMagentoSync(
    db,
    organizationId,
    listings.filter((l) => l.published || l.sync?.magentoId).map((l) => l.productId),
    reason,
  );
}
