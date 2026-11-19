import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { runMagentoSync, magentoRequest, MagentoError } from "../src/magento.js";
import { createServer } from "node:http";

/** A stand-in for Magento's REST API that records every request. */
function fakeMagento() {
  const calls: { method: string; path: string; body: any }[] = [];
  const products = new Map<string, any>();
  const categories = new Map<number, any>();
  let failNext = 0;
  const fetch = (async (url: string | URL, init: any = {}) => {
    const path = new URL(String(url)).pathname;
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method: init.method || "GET", path, body });
    const reply = (status: number, data: unknown) =>
      new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
    if (init.headers?.Authorization !== "Bearer test-token")
      return reply(401, { message: "The consumer isn't authorized to access %resources.", parameters: { resources: "Magento_Catalog::products" } });
    if (failNext > 0) {
      failNext--;
      return reply(500, { message: "Internal error. Details are available in Magento log file." });
    }
    // Categories under the root category (2), found by name or created.
    if (path === "/rest/all/V1/categories/list") {
      const u = new URL(String(url));
      const name = u.searchParams.get("searchCriteria[filter_groups][0][filters][0][value]");
      const items = [...categories.values()].filter((c) => c.name === name);
      return reply(200, { items, total_count: items.length });
    }
    if (path === "/rest/all/V1/categories" && init.method === "POST") {
      const c = { id: 100 + categories.size, ...body.category };
      categories.set(c.id, c);
      return reply(200, c);
    }
    if (path === "/rest/V1/store/storeConfigs")
      return reply(200, [{ code: "default", base_currency_code: "INR", secure_base_url: "https://shop.example/" }]);
    const match = path.match(/^\/rest\/all\/V1\/products\/(.+)$/);
    if (match && init.method === "PUT") {
      const sku = decodeURIComponent(match[1]);
      const saved = { id: products.get(sku)?.id || products.size + 101, ...body.product };
      products.set(body.product.sku, saved);
      return reply(200, saved);
    }
    return reply(404, { message: "Request does not match any route." });
  }) as typeof globalThis.fetch;
  return { fetch, calls, products, categories, failNextRequests: (n: number) => (failNext = n) };
}

test("Magento: publish, price, stock follows POS sales, retries and permissions", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const magento = fakeMagento();
  const app = await createApp(db, { fetch: magento.fetch });
  try {
    const call = async (path: string, body: any, token?: string, status = 200, method = "POST") => {
      const response = await app.inject({
        method: method as any,
        url: "/api/v1/" + path,
        payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(response.statusCode, status, `${path}: ${response.body}`);
      return response.json();
    };
    const login = async (email: string) => (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const manager = await login("manager@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const lastPut = (sku: string) => [...magento.calls].reverse().find((c) => c.method === "PUT" && c.path.endsWith(sku))!.body.product;

    // Connect: owner only, all fields required to switch on, token never returned.
    await call("integrations/magento", { baseUrl: "http://magento.test", enabled: true }, owner, 400);
    await call("integrations/magento", { baseUrl: "http://magento.test", token: "x" }, manager, 403);
    const config = await call(
      "integrations/magento",
      { baseUrl: "http://magento.test/", token: "test-token", branchId: "pune", defaultBuffer: 1, enabled: true },
      owner,
    );
    assert.equal(config.baseUrl, "http://magento.test");
    assert.equal(config.tokenSet, true);
    assert.equal("token" in config, false);
    const check = await call("integrations/magento/test", {}, manager);
    assert.equal(check.currency, "INR");

    // Publish the oil filter at 10% off MRP. MRP = 285.00 + 18% GST = 336.30.
    await call("online-listings", { productIds: ["filter"], changes: { published: true } }, cashier, 403);
    await call("online-listings", { productIds: ["filter"], changes: { pricing: { mode: "fixed", price: 999999 } } }, owner, 400);
    const [listing] = await call(
      "online-listings",
      { productIds: ["filter"], changes: { published: true, pricing: { mode: "percent", percent: 1000 }, description: "Spin-on oil filter" } },
      manager,
    );
    assert.equal(listing.sync.state, "pending");
    assert.deepEqual(await runMagentoSync(db, { fetch: magento.fetch }), { sent: 1, failed: 0 });
    let product = lastPut("ML-FILTER-01");
    assert.equal(product.sku, "ML-FILTER-01");
    assert.equal(product.visibility, 4);
    assert.deepEqual(product.extension_attributes.website_ids, [1]);
    assert.equal(product.price, 336.3);
    assert.equal(product.custom_attributes.find((a: any) => a.attribute_code === "special_price").value, "302.67");
    assert.equal(product.status, 1);
    assert.equal(product.extension_attributes.stock_item.qty, 23); // 24 in Pune - 1 buffer
    assert.equal(product.extension_attributes.stock_item.is_in_stock, true);
    // The POS category ("Parts") was created under the root category and linked.
    const parts = [...magento.categories.values()].find((c) => c.name === "Parts");
    assert.equal(parts.parent_id, 2);
    assert.equal(parts.include_in_menu, true);
    assert.deepEqual(product.extension_attributes.category_links, [{ position: 0, category_id: String(parts.id) }]);
    let saved = await getRecord(db, "demo", "onlineListing", "filter");
    assert.equal(saved!.sync.state, "synced");
    assert.equal(saved!.sync.magentoSku, "ML-FILTER-01");
    assert.equal(await getRecord(db, "demo", "magentoJob", "filter"), undefined);

    // A counter sale in Pune lowers the website stock.
    const shift = await call("shifts/open", { openingCash: 0 }, cashier);
    await call(
      "invoices",
      {
        transactionId: randomUUID(),
        shiftId: shift.id,
        lines: [{ productId: "filter", qty: 2, binId: "bin-a1" }],
        tenders: [{ type: "Cash", amount: 100000, confirmed: true }],
      },
      cashier,
    );
    assert.equal((await getRecord(db, "demo", "onlineListing", "filter"))!.sync.state, "pending");
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal(lastPut("ML-FILTER-01").extension_attributes.stock_item.qty, 21);

    // Unpublished parts and other branches do not send anything.
    const before = magento.calls.length;
    await call("online-listings", { productIds: ["brake"], changes: { pricing: { mode: "percent", percent: 500 } } }, owner);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal(magento.calls.length, before);

    // Another part in the same category reuses it (looked up once, remembered).
    await call("online-listings", { productIds: ["spark"], changes: { published: true } }, owner);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal([...magento.categories.values()].filter((c) => c.name === "Parts").length, 1);
    assert.equal(magento.calls.filter((c) => c.method === "POST" && c.path === "/rest/all/V1/categories").length, 1);
    assert.equal(lastPut("ML-SPARK-01").extension_attributes.category_links[0].category_id, String(parts.id));

    // Magento down: the part shows the error, the job waits, and Retry sends it again.
    magento.failNextRequests(1);
    await call("online-listings", { productIds: ["filter"], changes: { availability: "order", leadDays: 10 } }, owner);
    assert.deepEqual(await runMagentoSync(db, { fetch: magento.fetch }), { sent: 0, failed: 1 });
    saved = await getRecord(db, "demo", "onlineListing", "filter");
    assert.equal(saved!.sync.state, "error");
    assert.match(saved!.sync.error, /Internal error/);
    const job = await getRecord(db, "demo", "magentoJob", "filter");
    assert.ok(job!.nextAt > new Date().toISOString());
    assert.deepEqual(await runMagentoSync(db, { fetch: magento.fetch }), { sent: 0, failed: 0 }); // waiting for backoff
    await call("integrations/magento/retry", {}, manager);
    assert.deepEqual(await runMagentoSync(db, { fetch: magento.fetch }), { sent: 1, failed: 0 });
    product = lastPut("ML-FILTER-01");
    assert.equal(product.extension_attributes.stock_item.backorders, 2);
    assert.match(product.custom_attributes.find((a: any) => a.attribute_code === "short_description").value, /10 days/);

    // Unpublish disables the product in Magento instead of deleting it.
    await call("online-listings", { productIds: ["filter"], changes: { published: false } }, owner);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal(lastPut("ML-FILTER-01").status, 2);
    assert.equal((await getRecord(db, "demo", "onlineListing", "filter"))!.sync.state, "unpublished");

    // Managers see listings; nobody receives the token.
    const boot = (await app.inject({ method: "GET", url: "/api/v1/bootstrap", headers: { authorization: "Bearer " + manager } })).json();
    assert.equal(boot.onlineListings.length, 3);
    assert.equal(JSON.stringify(boot).includes("test-token"), false);
    const cashierBoot = (await app.inject({ method: "GET", url: "/api/v1/bootstrap", headers: { authorization: "Bearer " + cashier } })).json();
    assert.deepEqual(cashierBoot.onlineListings, []);

    // A wrong token is reported in plain words.
    await call("integrations/magento", { token: "wrong" }, owner);
    await call("online-listings", { productIds: ["filter"], changes: { published: true } }, owner);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.match((await getRecord(db, "demo", "onlineListing", "filter"))!.sync.error, /isn't authorized/);
    const bad = await call("integrations/magento/test", {}, owner, 502);
    assert.match(bad.error, /isn't authorized/);
  } finally {
    await app.close();
    await db.close();
  }
});

test("Magento: stock changes in a branch that does not sell online are ignored", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const settings = (await getRecord(db, "demo", "settings", "settings"))!;
  settings.integrations = { magento: { enabled: true, baseUrl: "http://magento.test", branchId: "mumbai", tokenSet: true } };
  await putRecord(db, "demo", "settings", settings);
  await putRecord(db, "demo", "onlineListing", { id: "filter", productId: "filter", published: true, sync: { state: "synced" } });
  const app = await createApp(db);
  try {
    const { token } = (
      await app.inject({ method: "POST", url: "/api/v1/auth/login", payload: { email: "owner@motorline.local", password: "MotorlineDemo123!", branchId: "pune" } })
    ).json();
    const adjust = async () => {
      const response = await app.inject({
        method: "POST",
        url: "/api/v1/inventory/adjust",
        payload: { productId: "filter", binId: "bin-a1", quantity: -1, reason: "Damaged", transactionId: randomUUID() },
        headers: { authorization: "Bearer " + token },
      });
      assert.equal(response.statusCode, 200, response.body);
    };
    await adjust();
    assert.equal(await getRecord(db, "demo", "magentoJob", "filter"), undefined);
    // The same change in the online branch is queued.
    settings.integrations.magento.branchId = "pune";
    await putRecord(db, "demo", "settings", settings);
    await adjust();
    assert.equal((await getRecord(db, "demo", "magentoJob", "filter"))!.reason, "Damaged");
  } finally {
    await app.close();
    await db.close();
  }
});

test("Magento: requests go over real HTTP with the token, and errors read clearly", async () => {
  const seen: { method?: string; url?: string; auth?: string; body: string }[] = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body });
      res.setHeader("Content-Type", "application/json");
      if (req.url?.includes("missing")) {
        res.statusCode = 400;
        res.end(JSON.stringify({ message: "The \"%1\" attribute set doesn't exist.", parameters: ["99"] }));
      } else res.end(JSON.stringify({ id: 7, sku: "A-1" }));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${(server.address() as any).port}`;
  try {
    const ok = await magentoRequest(fetch, base, "tok", "PUT", "/all/V1/products/A-1", { product: { sku: "A-1" } });
    assert.deepEqual(ok, { id: 7, sku: "A-1" });
    assert.equal(seen[0].auth, "Bearer tok");
    assert.equal(seen[0].url, "/rest/all/V1/products/A-1");
    assert.equal(JSON.parse(seen[0].body).product.sku, "A-1");
    await assert.rejects(
      magentoRequest(fetch, base, "tok", "PUT", "/all/V1/products/missing", {}),
      (e: any) => e instanceof MagentoError && e.message === `The "99" attribute set doesn't exist.`,
    );
    await assert.rejects(magentoRequest(fetch, "http://127.0.0.1:1", "tok", "GET", "/V1/store/storeConfigs"), /Cannot reach Magento/);
  } finally {
    server.close();
  }
});
