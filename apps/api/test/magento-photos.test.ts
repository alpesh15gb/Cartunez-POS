import { test } from "node:test";
import assert from "node:assert/strict";
import { connectDatabase, migrate, getRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { runMagentoSync } from "../src/magento.js";
import { compareMagento } from "../src/magento-check.js";

// A 1×1 JPEG and a 1×1 PNG.
const JPEG =
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==";
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/** Magento that keeps products and their photos, so the POS can be compared with it. */
function fakeMagento() {
  const products = new Map<string, any>();
  const media = new Map<string, Map<number, any>>();
  const calls: { method: string; path: string; body?: any }[] = [];
  let nextEntry = 1;
  const fetch = (async (url: string | URL, init: any = {}) => {
    const path = decodeURIComponent(new URL(String(url)).pathname);
    const method = init.method || "GET";
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method, path, body });
    const reply = (status: number, data: unknown) => new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
    let m: RegExpMatchArray | null;
    if ((m = path.match(/^\/rest\/all\/V1\/products\/([^/]+)\/media\/(\d+)$/))) {
      const gallery = media.get(m[1]) || new Map();
      if (method === "DELETE") {
        if (!gallery.has(Number(m[2])) && state.failMissingMedia) return reply(404, { message: "Request does not match any route." });
        return reply(200, gallery.delete(Number(m[2])));
      }
      gallery.set(Number(m[2]), { ...gallery.get(Number(m[2])), ...body.entry });
      return reply(200, true);
    }
    if ((m = path.match(/^\/rest\/all\/V1\/products\/([^/]+)\/media$/))) {
      const gallery = media.get(m[1]) || new Map();
      const id = nextEntry++;
      gallery.set(id, { ...body.entry, content: undefined, size: Buffer.from(body.entry.content.base64_encoded_data, "base64").length });
      media.set(m[1], gallery);
      return reply(200, String(id));
    }
    if ((m = path.match(/^\/rest\/all\/V1\/products\/([^/]+)$/))) {
      if (method === "PUT") {
        products.set(body.product.sku, { id: 7, ...body.product });
        return reply(200, products.get(body.product.sku));
      }
      const p = products.get(m[1]);
      return p ? reply(200, p) : reply(404, { message: "The product that was requested doesn't exist. Verify the product and try again." });
    }
    return reply(404, { message: "Not found" });
  }) as typeof globalThis.fetch;
  const state = { fetch, products, media, calls, failMissingMedia: false };
  return state;
}

test("Product photos: upload, show, send to Magento, reorder, delete; daily comparison fixes drift", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const magento = fakeMagento();
  const app = await createApp(db, { fetch: magento.fetch });
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({ method: method as any, url: "/api/v1/" + path, payload: body, headers: token ? { authorization: "Bearer " + token } : {} });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const inventory = await login("inventory@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const sync = () => runMagentoSync(db, { fetch: magento.fetch });
    const gallery = () => [...(magento.media.get("ML-FILTER-01") || new Map()).entries()];

    // Uploads: inventory staff may add photos; only real JPEG/PNG/WebP files are accepted.
    await call("products/filter/images", { contentType: "image/jpeg", data: JPEG }, cashier, 403);
    await call("products/filter/images", { contentType: "image/gif", data: JPEG }, inventory, 400);
    await call("products/filter/images", { contentType: "image/jpeg", data: PNG }, inventory, 400);
    const first = await call("products/filter/images", { contentType: "image/jpeg", data: JPEG, width: 1, height: 1 }, inventory);
    assert.equal(first.position, 0);
    assert.equal("data" in first, false);

    // The app gets photo details at sign-in (never the bytes) and loads each photo separately.
    const boot = (await app.inject({ method: "GET", url: "/api/v1/bootstrap", headers: { authorization: "Bearer " + cashier } })).json();
    assert.deepEqual(boot.productImages.map((i: any) => [i.id, i.productId, "data" in i]), [[first.id, "filter", false]]);
    const bytes = await app.inject({ method: "GET", url: `/api/v1/product-images/${first.id}`, headers: { authorization: "Bearer " + cashier } });
    assert.equal(bytes.statusCode, 200);
    assert.equal(bytes.headers["content-type"], "image/jpeg");
    assert.deepEqual(bytes.rawPayload, Buffer.from(JPEG, "base64"));

    // Publishing sends the product and its photo; the photo becomes Magento's main image.
    await call("integrations/magento", { baseUrl: "http://magento.test", token: "t", branchId: "pune", enabled: true }, owner);
    await call("online-listings", { productIds: ["filter"], changes: { published: true } }, owner);
    await sync();
    assert.equal(gallery().length, 1);
    assert.deepEqual(gallery()[0][1].types, ["image", "small_image", "thumbnail"]);
    assert.equal(gallery()[0][1].size, Buffer.from(JPEG, "base64").length);
    let listing = await getRecord(db, "demo", "onlineListing", "filter");
    assert.equal(listing!.sync.mainImageId, first.id);
    await sync(); // nothing queued; and syncing again never re-uploads
    await call("online-listings", { productIds: ["filter"], changes: { leadDays: 3 } }, owner);
    await sync();
    assert.equal(gallery().length, 1);

    // A second photo made the main one; then the first is deleted.
    const second = await call("products/filter/images", { contentType: "image/png", data: PNG }, inventory);
    await call("products/filter/images/order", { imageIds: [second.id, first.id] }, inventory);
    await sync();
    assert.equal(gallery().length, 2);
    const secondEntry = (await getRecord(db, "demo", "onlineListing", "filter"))!.sync.media[second.id];
    assert.deepEqual(magento.media.get("ML-FILTER-01")!.get(secondEntry).types, ["image", "small_image", "thumbnail"]);
    const del = await app.inject({ method: "DELETE", url: `/api/v1/products/filter/images/${first.id}`, headers: { authorization: "Bearer " + inventory } });
    assert.equal(del.statusCode, 200, del.body);
    await sync();
    assert.deepEqual(gallery().map(([id]) => id), [secondEntry]);
    listing = await getRecord(db, "demo", "onlineListing", "filter");
    assert.deepEqual(Object.keys(listing!.sync.media), [second.id]);

    // A photo already removed in the Magento admin is not an error when the POS removes it too.
    const third = await call("products/filter/images", { contentType: "image/png", data: PNG }, inventory);
    await sync();
    const thirdEntry = (await getRecord(db, "demo", "onlineListing", "filter"))!.sync.media[third.id];
    magento.media.get("ML-FILTER-01")!.delete(thirdEntry);
    magento.failMissingMedia = true;
    await app.inject({ method: "DELETE", url: `/api/v1/products/filter/images/${third.id}`, headers: { authorization: "Bearer " + inventory } });
    assert.deepEqual(await sync(), { sent: 1, failed: 0 });
    magento.failMissingMedia = false;

    // Daily comparison: someone changed the stock and price in the Magento admin.
    const mg = magento.products.get("ML-FILTER-01");
    mg.extension_attributes.stock_item.qty = 99;
    mg.price = 1;
    let [result] = await compareMagento(db, { fetch: magento.fetch, organizationId: "demo" });
    assert.equal(result.checked, 1);
    assert.equal(result.differences, 2);
    const check = await getRecord(db, "demo", "magentoCheck", "latest");
    assert.deepEqual(check!.differences.map((d: any) => d.field).sort(), ["mrp", "qty"]);
    assert.equal(check!.partsFixed, 1);
    await sync();
    [result] = await compareMagento(db, { fetch: magento.fetch, organizationId: "demo" });
    assert.equal(result.differences, 0);

    // A product deleted in Magento is noticed and recreated.
    magento.products.delete("ML-FILTER-01");
    [result] = await compareMagento(db, { fetch: magento.fetch, organizationId: "demo" });
    assert.equal(result.differences, 1);
    await sync();
    assert.ok(magento.products.has("ML-FILTER-01"));

    // Managers can run it from the screen; the result reaches the app.
    const now = await call("integrations/magento/compare", {}, owner);
    assert.equal(now.differences, 0);
    await call("integrations/magento/compare", {}, cashier, 403);
    const ownerBoot = (await app.inject({ method: "GET", url: "/api/v1/bootstrap", headers: { authorization: "Bearer " + owner } })).json();
    assert.equal(ownerBoot.magentoCheck.checked, 1);

    // At most 8 photos per part.
    for (let i = 0; i < 7; i++) await call("products/filter/images", { contentType: "image/png", data: PNG }, inventory);
    await call("products/filter/images", { contentType: "image/png", data: PNG }, inventory, 400);
    assert.equal((await getRecord(db, "demo", "product", "filter"))!.id, "filter");
  } finally {
    await app.close();
    await db.close();
  }
});
