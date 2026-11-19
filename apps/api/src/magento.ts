// Magento 2 integration: online listings (what is published and at what
// price), the sync worker that pushes products and stock to Magento, and the
// connection settings. The POS is the source of truth; Magento follows it.
import type { FastifyInstance } from "fastify";
import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { allow, fail, integer, text, type Actor } from "./domain.js";
import { magentoConfig, queueAllListings, queueMagentoSync } from "./online-queue.js";
import { productImageData, productImages } from "./product-images.js";

type Post = (
  path: string,
  handler: (db: Database, actor: Actor, body: any, params: any) => Promise<any>,
) => unknown;
type Fetch = typeof globalThis.fetch;

export const availabilities = ["stock", "order", "hidden"] as const;
export const priceModes = ["mrp", "percent", "fixed"] as const;

// ---------- Prices and quantities ----------

/** MRP (price including tax) and the online selling price, in paise. */
export function onlinePrices(product: any, settings: any, listing: any) {
  const retail = Number(product.retailPrice || 0);
  const mrp =
    settings?.taxMode === "inclusive"
      ? retail
      : Math.round(retail + (retail * Number(product.taxRate || 0)) / 10000);
  const pricing = listing?.pricing || { mode: "mrp" };
  const selling =
    pricing.mode === "percent"
      ? Math.round((mrp * (10000 - Number(pricing.percent || 0))) / 10000)
      : pricing.mode === "fixed"
        ? Number(pricing.price || mrp)
        : mrp;
  return { mrp, selling };
}

/** Stock the website may sell: the online branch's stock, minus parked sales and the buffer. */
export async function onlineQuantity(
  db: Database,
  organizationId: string,
  branchId: string,
  productId: string,
  buffer: number,
) {
  const onHand = Number(
    (
      await db.query(
        "SELECT COALESCE(SUM(quantity),0) AS q FROM stock WHERE organization_id=$1 AND branch_id=$2 AND product_id=$3",
        [organizationId, branchId, productId],
      )
    ).rows[0]?.q || 0,
  );
  const holds = await records(db, organizationId, "hold", branchId);
  const parked = holds.reduce(
    (sum, hold) =>
      sum +
      (hold.cart?.lines || [])
        .filter((line: any) => line.productId === productId)
        .reduce((s: number, line: any) => s + Number(line.qty || 0), 0),
    0,
  );
  return Math.max(0, onHand - parked - buffer);
}

const slug = (value: string) =>
  value
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);

/** The product as Magento's REST API expects it (prices in rupees). */
export function magentoProduct(
  product: any,
  listing: any,
  prices: { mrp: number; selling: number },
  qty: number,
  config: any,
  categoryId: number | null = null,
) {
  const published = !!listing.published;
  const onOrder = listing.availability === "order";
  const inStock = qty > 0 || onOrder;
  const hide = listing.availability === "hidden" && qty <= 0;
  const custom: { attribute_code: string; value: string }[] = [
    // Special price equal to the price shows a single price (no strike-through).
    { attribute_code: "special_price", value: (prices.selling / 100).toFixed(2) },
    { attribute_code: "url_key", value: slug(`${product.name}-${product.sku}`) },
  ];
  if (listing.description) custom.push({ attribute_code: "description", value: listing.description });
  if (onOrder)
    custom.push({
      attribute_code: "short_description",
      value: `Available on order. Ships in ${listing.leadDays || 7} days.`,
    });
  return {
    product: {
      sku: product.sku,
      name: product.name,
      attribute_set_id: Number(config.attributeSetId || 4),
      type_id: "simple",
      price: Number((prices.mrp / 100).toFixed(2)),
      status: published ? 1 : 2,
      visibility: hide ? 1 : 4,
      weight: 1,
      extension_attributes: {
        website_ids: [Number(config.websiteId || 1)],
        // The POS category decides the shop category (one per part).
        category_links: categoryId ? [{ position: 0, category_id: String(categoryId) }] : [],
        stock_item: {
          qty,
          is_in_stock: inStock,
          manage_stock: true,
          use_config_backorders: false,
          // 2 = allow backorders and notify the customer.
          backorders: onOrder ? 2 : 0,
        },
      },
      custom_attributes: custom,
    },
  };
}

// ---------- Magento HTTP ----------

export class MagentoError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
  }
}

function magentoMessage(body: any, status: number) {
  if (body && typeof body.message === "string") {
    let message: string = body.message;
    const params = body.parameters;
    if (Array.isArray(params)) params.forEach((p, i) => (message = message.replace(`%${i + 1}`, String(p))));
    else if (params && typeof params === "object")
      for (const [k, v] of Object.entries(params)) message = message.replace(`%${k}`, String(v));
    return message;
  }
  if (status === 401) return "Magento rejected the access token. Create a new integration token.";
  if (status === 404) return "Magento API not found at this address. Check the store URL.";
  return `Magento answered with HTTP ${status}.`;
}

export async function magentoRequest(
  fetchImpl: Fetch,
  baseUrl: string,
  token: string,
  method: string,
  path: string,
  body?: unknown,
) {
  let response: Response;
  try {
    response = await fetchImpl(`${baseUrl}/rest${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(20000),
    });
  } catch (error: any) {
    throw new MagentoError(`Cannot reach Magento at ${baseUrl}: ${error?.cause?.code || error?.message || error}`);
  }
  const raw = await response.text();
  let parsed: any = null;
  try {
    parsed = raw ? JSON.parse(raw) : null;
  } catch {
    parsed = null;
  }
  if (!response.ok) throw new MagentoError(magentoMessage(parsed, response.status), response.status);
  return parsed;
}

// ---------- Categories ----------

/**
 * The Magento category for a POS category name, under the store's root
 * category: found by name, or created (visible in the menu). Remembered so
 * each category is looked up once.
 */
export async function magentoCategoryId(
  fetchImpl: Fetch,
  baseUrl: string,
  token: string,
  db: Database,
  org: string,
  config: any,
  name: unknown,
): Promise<number | null> {
  const label = String(name ?? "").trim();
  if (!label) return null;
  const key = `cat-${slug(label) || "x"}`;
  const cached = await getRecord(db, org, "magentoCategory", key);
  if (cached?.categoryId) return Number(cached.categoryId);
  const root = Number(config.rootCategoryId || 2);
  const q = new URLSearchParams({
    "searchCriteria[filter_groups][0][filters][0][field]": "name",
    "searchCriteria[filter_groups][0][filters][0][value]": label,
    "searchCriteria[filter_groups][0][filters][0][condition_type]": "eq",
    "searchCriteria[filter_groups][1][filters][0][field]": "parent_id",
    "searchCriteria[filter_groups][1][filters][0][value]": String(root),
    "searchCriteria[filter_groups][1][filters][0][condition_type]": "eq",
  });
  const found = await magentoRequest(fetchImpl, baseUrl, token, "GET", `/all/V1/categories/list?${q}`);
  let id = Number(found?.items?.[0]?.id || 0);
  if (!id) {
    const created = await magentoRequest(fetchImpl, baseUrl, token, "POST", "/all/V1/categories", {
      category: { parent_id: root, name: label, is_active: true, include_in_menu: true },
    });
    id = Number(created?.id || 0);
  }
  if (!id) throw new MagentoError(`Magento did not return a category for "${label}".`);
  await putRecord(db, org, "magentoCategory", { id: key, name: label, categoryId: id });
  return id;
}

/** Forgets remembered categories (for example after one was deleted in Magento). */
async function forgetCategories(db: Database, org: string) {
  await db.query("DELETE FROM records WHERE organization_id=$1 AND kind='magentoCategory'", [org]);
}

// ---------- Photos ----------

/**
 * Brings Magento's product photos in line with the POS. [synced] maps POS photo
 * IDs to Magento media entry IDs from earlier syncs, so photos are sent once.
 */
export async function syncPhotos(
  fetchImpl: Fetch,
  baseUrl: string,
  token: string,
  db: Database,
  org: string,
  product: any,
  synced: { media?: Record<string, number>; mainImageId?: string | null },
) {
  const media: Record<string, number> = { ...(synced.media || {}) };
  const sku = encodeURIComponent(product.sku);
  const images = await productImages(db, org, product.id);
  const main = images[0]?.id ?? null;
  const roles = ["image", "small_image", "thumbnail"];
  for (const image of images) {
    if (media[image.id]) continue;
    const full = await productImageData(db, org, image.id);
    if (!full) continue;
    const ext = full.contentType === "image/png" ? "png" : full.contentType === "image/webp" ? "webp" : "jpg";
    const entryId = await magentoRequest(fetchImpl, baseUrl, token, "POST", `/all/V1/products/${sku}/media`, {
      entry: {
        media_type: "image",
        label: product.name,
        position: image.position,
        disabled: false,
        types: image.id === main ? roles : [],
        content: { base64_encoded_data: full.data, type: full.contentType, name: `${slug(product.sku)}-${image.id}.${ext}` },
      },
    });
    media[image.id] = Number(entryId);
  }
  for (const [imageId, entryId] of Object.entries(media)) {
    if (images.some((i: any) => i.id === imageId)) continue;
    try {
      await magentoRequest(fetchImpl, baseUrl, token, "DELETE", `/all/V1/products/${sku}/media/${entryId}`);
    } catch (e) {
      // Already gone from Magento (for example removed in its admin): nothing to do.
      if (!(e instanceof MagentoError && (e.status === 404 || /doesn't exist|not exist|no image/i.test(e.message)))) throw e;
    }
    delete media[imageId];
  }
  // A different photo was made the main one: give it the main-image roles.
  if (main && synced.mainImageId && synced.mainImageId !== main && synced.media?.[main]) {
    await magentoRequest(fetchImpl, baseUrl, token, "PUT", `/all/V1/products/${sku}/media/${media[main]}`, {
      entry: { id: media[main], media_type: "image", label: product.name, position: 0, disabled: false, types: roles },
    });
  }
  return { media, mainImageId: main };
}

// ---------- Sync worker ----------

const backoffMs = (attempts: number) => Math.min(2 ** attempts * 30_000, 3_600_000);

/** Sends due Magento jobs. Network calls happen outside database transactions. */
export async function runMagentoSync(db: Database, options: { fetch?: Fetch; limit?: number } = {}) {
  const fetchImpl = options.fetch || globalThis.fetch;
  const due = (
    await db.query(
      "SELECT organization_id, data FROM records WHERE kind='magentoJob' AND data->>'nextAt' <= $1 ORDER BY data->>'nextAt' LIMIT $2",
      [new Date().toISOString(), options.limit || 20],
    )
  ).rows as { organization_id: string; data: any }[];
  let sent = 0;
  let failed = 0;
  for (const { organization_id: org, data: job } of due) {
    const settings = await getRecord(db, org, "settings", "settings");
    const config = magentoConfig(settings);
    const secret = await getRecord(db, org, "integrationSecret", "magento");
    const product = await getRecord(db, org, "product", job.productId);
    const listing = await getRecord(db, org, "onlineListing", job.productId);
    let result: any;
    let error: string | null = null;
    let qty = 0;
    let photos: { media?: Record<string, number>; mainImageId?: string | null } = {};
    const prices = product && listing ? onlinePrices(product, settings, listing) : { mrp: 0, selling: 0 };
    try {
      if (!config.enabled || !config.baseUrl || !secret?.token) throw new MagentoError("Magento is not connected.");
      if (!product || !listing) throw new MagentoError("This part no longer exists in the POS.");
      const buffer = listing.buffer ?? config.defaultBuffer ?? 0;
      qty = await onlineQuantity(db, org, config.branchId, product.id, buffer);
      // A part whose SKU changed is updated under the SKU Magento knows.
      const path = encodeURIComponent(listing.sync?.magentoSku || product.sku);
      result = await magentoRequest(
        fetchImpl,
        config.baseUrl,
        secret.token,
        "PUT",
        `/all/V1/products/${path}`,
        magentoProduct(
          product,
          listing,
          prices,
          qty,
          config,
          listing.published
            ? await magentoCategoryId(fetchImpl, config.baseUrl, secret.token, db, org, config, product.category)
            : null,
        ),
      );
      // Photos: upload new ones, remove deleted ones, keep the main photo first.
      if (listing.published) {
        photos = await syncPhotos(fetchImpl, config.baseUrl, secret.token, db, org, product, listing.sync || {});
        // Saved now so a later failure does not upload the same photos twice.
        await putRecord(db, org, "onlineListing", {
          ...((await getRecord(db, org, "onlineListing", product.id)) || listing),
          sync: { ...((await getRecord(db, org, "onlineListing", product.id))?.sync || {}), ...photos },
        });
      }
      sent++;
    } catch (e: any) {
      error = e instanceof MagentoError ? e.message : `Sync failed: ${e?.message || e}`;
      // A category removed in Magento's admin: look it up again on the retry.
      if (e instanceof MagentoError && /categor/i.test(e.message)) await forgetCategories(db, org);
      failed++;
    }
    await db.transaction(async (tx) => {
      const current = await getRecord(tx, org, "magentoJob", job.productId);
      const latest = await getRecord(tx, org, "onlineListing", job.productId);
      const changedMeanwhile = !current || current.version !== job.version;
      if (latest) {
        await putRecord(tx, org, "onlineListing", {
          ...latest,
          sync: error
            ? { ...(latest.sync || {}), state: "error", error, at: new Date().toISOString() }
            : {
                ...(latest.sync || {}),
                state: changedMeanwhile ? "pending" : latest.published ? "synced" : "unpublished",
                magentoId: result?.id ?? latest.sync?.magentoId ?? null,
                magentoSku: result?.sku || product?.sku,
                ...photos,
                qty,
                mrp: prices.mrp,
                price: prices.selling,
                error: null,
                at: new Date().toISOString(),
              },
        });
      }
      if (changedMeanwhile) return; // a newer change is queued; it will run next
      if (error) {
        const attempts = (current.attempts || 0) + 1;
        await putRecord(tx, org, "magentoJob", {
          ...current,
          attempts,
          error,
          nextAt: new Date(Date.now() + backoffMs(attempts)).toISOString(),
        });
      } else {
        await tx.query("DELETE FROM records WHERE organization_id=$1 AND kind='magentoJob' AND id=$2", [org, job.productId]);
      }
    });
  }
  return { sent, failed };
}

/** Runs the sync every [intervalMs] in the API process. Returns a stop function. */
export function startMagentoWorker(db: Database, intervalMs = 5000) {
  let running = false;
  const timer = setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await runMagentoSync(db);
    } catch (error) {
      console.error("Magento sync error", error);
    } finally {
      running = false;
    }
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

// ---------- Settings and listings ----------

function storeUrl(value: unknown) {
  const raw = text(value, "Magento store URL", true, 300).replace(/\/+$/, "");
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    fail("Enter the Magento store address, for example https://shop.cartunez.in");
  }
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url!.hostname);
  if (url!.protocol !== "https:" && !(url!.protocol === "http:" && (local || process.env.NODE_ENV !== "production")))
    fail("The Magento store address must start with https://");
  return raw;
}

function listingChanges(body: any) {
  const c: any = {};
  if (body.published !== undefined) {
    if (typeof body.published !== "boolean") fail("Published must be on or off.");
    c.published = body.published;
  }
  if (body.availability !== undefined) {
    if (!availabilities.includes(body.availability)) fail("Choose In stock, On order or Hidden when out of stock.");
    c.availability = body.availability;
  }
  if (body.leadDays !== undefined) c.leadDays = integer(body.leadDays, "Lead time (days)", 0, 365);
  if (body.buffer !== undefined) c.buffer = body.buffer === null ? null : integer(body.buffer, "Safety buffer", 0, 9999);
  if (body.description !== undefined) c.description = text(body.description, "Website description", false, 5000);
  if (body.pricing !== undefined) {
    const p = body.pricing || {};
    if (!priceModes.includes(p.mode)) fail("Choose MRP, % off MRP or a fixed price.");
    c.pricing =
      p.mode === "percent"
        ? { mode: "percent", percent: integer(p.percent, "Discount", 0, 9000) }
        : p.mode === "fixed"
          ? { mode: "fixed", price: integer(p.price, "Selling price", 1, 100000000000) }
          : { mode: "mrp" };
  }
  return c;
}

export function magentoRoutes(app: FastifyInstance, db: Database, post: Post, fetchImpl: () => Fetch = () => globalThis.fetch) {
  // Connection settings (owner). The token is stored apart from settings and never sent to clients.
  post("integrations/magento", async (tx, actor, body) => {
    allow(actor, ["owner"]);
    const settings = (await getRecord(tx, actor.organizationId, "settings", "settings"))!;
    const before = magentoConfig(settings);
    const next: any = { ...before };
    if (body.baseUrl !== undefined) next.baseUrl = storeUrl(body.baseUrl);
    if (body.branchId !== undefined) {
      const branch = await getRecord(tx, actor.organizationId, "branch", String(body.branchId));
      if (!branch) fail("Choose the branch that sells online.");
      next.branchId = branch!.id;
    }
    if (body.defaultBuffer !== undefined) next.defaultBuffer = integer(body.defaultBuffer, "Safety buffer", 0, 9999);
    if (body.attributeSetId !== undefined) next.attributeSetId = integer(body.attributeSetId, "Attribute set", 1, 1000000);
    if (body.websiteId !== undefined) next.websiteId = integer(body.websiteId, "Website", 1, 1000000);
    if (body.rootCategoryId !== undefined) next.rootCategoryId = integer(body.rootCategoryId, "Root category", 1, 1000000);
    if (body.token !== undefined && String(body.token).trim()) {
      await putRecord(tx, actor.organizationId, "integrationSecret", {
        id: "magento",
        token: text(body.token, "Magento access token", true, 500),
        savedAt: new Date().toISOString(),
      });
      next.tokenSet = true;
    }
    if (body.enabled !== undefined) {
      if (typeof body.enabled !== "boolean") fail("Choose whether Magento sync is on.");
      next.enabled = body.enabled;
    }
    if (next.enabled && (!next.baseUrl || !next.tokenSet || !next.branchId))
      fail("Enter the store address, access token and online branch before turning sync on.");
    next.defaultBuffer ??= 0;
    // Orders placed from this moment are read into the POS.
    if (next.enabled) next.connectedAt ??= new Date().toISOString();
    settings.integrations = { ...(settings.integrations || {}), magento: next };
    await putRecord(tx, actor.organizationId, "settings", settings);
    if (next.enabled && (!before.enabled || before.branchId !== next.branchId || before.baseUrl !== next.baseUrl))
      await queueAllListings(tx, actor.organizationId, "connected");
    return next;
  });

  // Checks the address and token by reading the store configuration (no transaction held).
  app.post("/api/v1/integrations/magento/test", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager"]);
    const body = request.body || {};
    const settings = await getRecord(db, actor.organizationId, "settings", "settings");
    const config = magentoConfig(settings);
    const baseUrl = body.baseUrl ? storeUrl(body.baseUrl) : config.baseUrl;
    const token = body.token ? String(body.token) : (await getRecord(db, actor.organizationId, "integrationSecret", "magento"))?.token;
    if (!baseUrl || !token) fail("Enter the store address and access token first.");
    try {
      const stores = await magentoRequest(fetchImpl(), baseUrl, token, "GET", "/V1/store/storeConfigs");
      const store = Array.isArray(stores) ? stores[0] : null;
      return {
        ok: true,
        stores: Array.isArray(stores) ? stores.length : 0,
        currency: store?.base_currency_code || null,
        baseUrl: store?.secure_base_url || store?.base_url || baseUrl,
      };
    } catch (error: any) {
      fail(error instanceof MagentoError ? error.message : String(error?.message || error), 502);
    }
  });

  // Bulk changes from the Online store screen: publish, price, availability, buffer.
  post("online-listings", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    const ids = body.productIds;
    if (!Array.isArray(ids) || !ids.length || ids.length > 1000) fail("Select between 1 and 1000 parts.");
    const changes = listingChanges(body.changes || {});
    if (!Object.keys(changes).length) fail("Choose what to change.");
    const settings = await getRecord(tx, actor.organizationId, "settings", "settings");
    const saved = [];
    for (const productId of new Set<string>(ids.map(String))) {
      const product = await getRecord(tx, actor.organizationId, "product", productId);
      if (!product) fail("A selected part no longer exists.", 404);
      if (product!.type === "service" && changes.published) fail(`${product!.name} is a service and cannot be sold online.`);
      const existing = (await getRecord(tx, actor.organizationId, "onlineListing", productId)) || {
        id: productId,
        productId,
        published: false,
        availability: "stock",
        leadDays: 7,
        pricing: { mode: "mrp" },
        buffer: null,
        description: "",
        sync: { state: "never" },
      };
      const listing = { ...existing, ...changes, updatedAt: new Date().toISOString(), updatedBy: actor.id };
      const prices = onlinePrices(product, settings, listing);
      if (prices.selling > prices.mrp)
        fail(`The selling price of ${product!.sku} cannot be above its MRP.`);
      if (prices.selling < 1) fail(`The selling price of ${product!.sku} must be above zero.`);
      await putRecord(tx, actor.organizationId, "onlineListing", listing);
      saved.push(listing);
    }
    await queueMagentoSync(tx, actor.organizationId, saved.map((l) => l.productId), "listing");
    return Promise.all(saved.map((l) => getRecord(tx, actor.organizationId, "onlineListing", l.productId)));
  });

  // Sends failed or all published parts again.
  post("integrations/magento/retry", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    if (body.all) {
      await queueAllListings(tx, actor.organizationId, "resend");
    } else {
      const listings = await records(tx, actor.organizationId, "onlineListing");
      await queueMagentoSync(tx, actor.organizationId, listings.filter((l) => l.sync?.state === "error").map((l) => l.productId), "retry");
    }
    return { queued: true };
  });
}
