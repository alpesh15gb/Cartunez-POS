import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, putRecord } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { runMagentoSync, magentoRequest, MagentoError, fitmentText, indiaToday, onSaleNow } from "../src/magento.js";
import { queueEndedSales } from "../src/magento-check.js";
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
      const parent = Number(u.searchParams.get("searchCriteria[filter_groups][1][filters][0][value]"));
      const items = [...categories.values()].filter((c) => c.name === name && c.parent_id === parent);
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

    await call("inventory/adjust", {
      productId: "filter", binId: "bin-damaged", quantity: 8, reason: "Damaged stock must stay off the website",
      transactionId: randomUUID(),
    }, owner);
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
    // Always orderable, the customer is never told: backorders without notice.
    assert.equal(product.extension_attributes.stock_item.backorders, 1);
    assert.equal(product.extension_attributes.stock_item.use_config_backorders, false);
    assert.equal(product.extension_attributes.stock_item.manage_stock, true);
    // Vehicle fitment for the shop's finder: one line per rule and a search word per year.
    const fit = product.custom_attributes.find((a: any) => a.attribute_code === "cz_fitment").value;
    assert.match(fit, /^V:Maruti Suzuki\|Swift\|2018\|2025$/m);
    assert.match(fit, /\bmarutisuzukiswift2018\b/);
    assert.match(fit, /\bmarutisuzukiswift2025\b/);
    assert.doesNotMatch(fit, /2017/);
    // The POS category ("Parts") was created under the root category and linked.
    const parts = [...magento.categories.values()].find((c) => c.name === "Parts");
    assert.equal(parts.parent_id, 2);
    assert.equal(parts.include_in_menu, true);
    // Its brand gets a page: Brands > Motorline Demo, under the root category.
    const brands = [...magento.categories.values()].find((c) => c.name === "Brands");
    assert.equal(brands.parent_id, 2);
    const brand = [...magento.categories.values()].find((c) => c.name === "Motorline Demo");
    assert.equal(brand.parent_id, brands.id);
    assert.deepEqual(product.extension_attributes.category_links, [
      { position: 0, category_id: String(parts.id) },
      { position: 0, category_id: String(brand.id) },
    ]);
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
    assert.equal(magento.calls.filter((c) => c.method === "POST" && c.path === "/rest/all/V1/categories").length, 3); // Parts, Brands, the brand
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
    // "On order" is internal only: same silent backorders, the old notice is cleared.
    assert.equal(product.extension_attributes.stock_item.backorders, 1);
    assert.equal(product.extension_attributes.stock_item.is_in_stock, true);
    assert.equal(product.custom_attributes.find((a: any) => a.attribute_code === "short_description").value, "");

    // "Hidden when out of stock" no longer hides: at 0 stock the part stays visible and orderable.
    await call("online-listings", { productIds: ["filter"], changes: { availability: "hidden", buffer: 1000 } }, owner);
    await runMagentoSync(db, { fetch: magento.fetch });
    product = lastPut("ML-FILTER-01");
    assert.equal(product.visibility, 4);
    assert.ok(product.extension_attributes.stock_item.qty <= 0);
    assert.equal(product.extension_attributes.stock_item.is_in_stock, true);
    assert.equal(product.extension_attributes.stock_item.backorders, 1);
    assert.equal(product.custom_attributes.find((a: any) => a.attribute_code === "short_description"), undefined);
    await call("online-listings", { productIds: ["filter"], changes: { availability: "stock", buffer: 1 } }, owner);

    // Unpublish disables the product in Magento instead of deleting it.
    await call("online-listings", { productIds: ["filter"], changes: { published: false } }, owner);
    await call("products", { id: "filter", salesAction: "stop" }, manager, 409);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal(lastPut("ML-FILTER-01").status, 2);
    assert.equal((await getRecord(db, "demo", "onlineListing", "filter"))!.sync.state, "unpublished");

    await call("products", { id: "filter", salesAction: "stop" }, manager);
    await call("online-listings", { productIds: ["filter"], changes: { published: true } }, owner, 409);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal(lastPut("ML-FILTER-01").status, 2);
    await call("products", { id: "filter", salesAction: "resume" }, manager);

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

test("Magento: fitment text for the vehicle finder", () => {
  const now = new Date("2026-06-01");
  // Universal parts, and parts with no vehicle rule, carry the universal marker.
  assert.equal(fitmentText({ universal: true }, now), "universal\nU:All vehicles");
  assert.equal(fitmentText({ fitments: [] }, now), "universal\nU:All vehicles");
  assert.equal(
    fitmentText({ universal: true, fitments: [{ make: "Tata", model: "Nexon", yearFrom: 2026 }] }, now),
    "universal\nU:All vehicles\nV:Tata|Nexon|2026|2026\ntatanexon2026",
  );
  const text = fitmentText(
    { fitments: [{ make: "Land Rover", model: "Range-Rover Evoque", yearFrom: 2024 }, { make: "Tata", model: "Nexon EV", yearFrom: 2023, yearTo: 2024 }] },
    now,
  );
  assert.deepEqual(text.split("\n"), [
    "V:Land Rover|Range-Rover Evoque|2024|2026",
    "V:Tata|Nexon EV|2023|2024",
    "landroverrangeroverevoque2024 landroverrangeroverevoque2025 landroverrangeroverevoque2026 tatanexonev2023 tatanexonev2024",
  ]);
  // Bad or reversed years are skipped rather than exploding into thousands of words.
  assert.equal(fitmentText({ fitments: [{ make: "A", model: "B", yearFrom: 2030, yearTo: 2020 }] }, now), "universal\nU:All vehicles");
});

test("Magento: parts on sale join the Sale category until the sale is removed or ends", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const magento = fakeMagento();
  const app = await createApp(db, { fetch: magento.fetch });
  try {
    const call = async (path: string, body: any, token?: string, status = 200) => {
      const response = await app.inject({
        method: "POST",
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
    const links = (sku: string) => lastPut(sku).extension_attributes.category_links.map((l: any) => Number(l.category_id));
    await call(
      "integrations/magento",
      { baseUrl: "http://magento.test/", token: "test-token", branchId: "pune", defaultBuffer: 0, enabled: true },
      owner,
    );
    await call("online-listings", { productIds: ["filter"], changes: { published: true, pricing: { mode: "percent", percent: 1000 } } }, owner);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal([...magento.categories.values()].some((c) => c.name === "Sale"), false);
    assert.equal(links("ML-FILTER-01").length, 2);

    // Cashiers cannot; past or malformed end dates are refused.
    await call("online-listings", { productIds: ["filter"], changes: { onSale: true } }, cashier, 403);
    await call("online-listings", { productIds: ["filter"], changes: { onSale: true, saleUntil: "2020-01-01" } }, owner, 400);
    await call("online-listings", { productIds: ["filter"], changes: { onSale: true, saleUntil: "2099-02-30" } }, owner, 400);
    await call("online-listings", { productIds: ["filter"], changes: { onSale: "yes" } }, owner, 400);

    // Put on sale (ending today is allowed): the PUT links the Sale category under the root.
    const today = indiaToday();
    const [listing] = await call("online-listings", { productIds: ["filter"], changes: { onSale: true, saleUntil: today } }, manager);
    assert.equal(listing.onSale, true);
    assert.equal(listing.saleUntil, today);
    await runMagentoSync(db, { fetch: magento.fetch });
    const sale = [...magento.categories.values()].find((c) => c.name === "Sale");
    assert.equal(sale.parent_id, 2);
    assert.equal(sale.include_in_menu, true);
    assert.ok(links("ML-FILTER-01").includes(sale.id));
    assert.equal((await getRecord(db, "demo", "onlineListing", "filter"))!.sync.onSale, true);
    const boot = (await app.inject({ method: "GET", url: "/api/v1/bootstrap", headers: { authorization: "Bearer " + manager } })).json();
    assert.equal(boot.onlineListings.find((l: any) => l.productId === "filter").onSale, true);

    // Remove from sale: the link is gone on the next sync and the end date is cleared.
    const [off] = await call("online-listings", { productIds: ["filter"], changes: { onSale: false } }, owner);
    assert.equal(off.onSale, false);
    assert.equal(off.saleUntil, null);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal(links("ML-FILTER-01").includes(sale.id), false);
    assert.equal(links("ML-FILTER-01").length, 2);

    // Without an end date the sale runs until removed; once the end date passes it is re-queued and dropped.
    await call("online-listings", { productIds: ["filter"], changes: { onSale: true } }, owner);
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.ok(links("ML-FILTER-01").includes(sale.id));
    assert.deepEqual(await queueEndedSales(db, "demo"), []);
    const current = (await getRecord(db, "demo", "onlineListing", "filter"))!;
    await putRecord(db, "demo", "onlineListing", { ...current, saleUntil: "2020-01-01" });
    assert.deepEqual(await queueEndedSales(db, "demo"), ["filter"]);
    assert.equal((await getRecord(db, "demo", "magentoJob", "filter"))!.reason, "sale ended");
    await runMagentoSync(db, { fetch: magento.fetch });
    assert.equal(links("ML-FILTER-01").includes(sale.id), false);
    assert.equal((await getRecord(db, "demo", "onlineListing", "filter"))!.sync.onSale, false);
    assert.deepEqual(await queueEndedSales(db, "demo"), []);
    // The category was created once and remembered.
    assert.equal([...magento.categories.values()].filter((c) => c.name === "Sale").length, 1);
  } finally {
    await app.close();
    await db.close();
  }
});

test("Magento: on sale now follows the India date", () => {
  assert.equal(indiaToday(new Date("2026-03-31T19:00:00Z")), "2026-04-01");
  const listing = { published: true, onSale: true, saleUntil: "2026-03-31" };
  assert.equal(onSaleNow(listing, new Date("2026-03-31T18:00:00Z")), true);
  assert.equal(onSaleNow(listing, new Date("2026-03-31T19:00:00Z")), false);
  assert.equal(onSaleNow({ ...listing, saleUntil: null }, new Date("2030-01-01")), true);
  assert.equal(onSaleNow({ ...listing, published: false }, new Date("2026-01-01")), false);
});
