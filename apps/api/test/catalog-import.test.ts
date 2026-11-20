import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createApp } from "../src/app.js";
import { connectDatabase, getRecord, migrate, records } from "../src/db.js";
import { seed } from "../src/seed.js";

test("product CSV preview, atomic import, replay, permissions and catalog identity", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    const login = async (email: string) => {
      const reply = await app.inject({ method: "POST", url: "/api/v1/auth/login",
        payload: { email, password: "MotorlineDemo123!" } });
      assert.equal(reply.statusCode, 200);
      return reply.json().token;
    };
    const owner = await login("owner@motorline.local");
    const cashier = await login("cashier@motorline.local");
    const post = async (path: string, body: any, status = 200, token = owner) => {
      const result = await app.inject({ method: "POST", url: "/api/v1/" + path, payload: body,
        headers: { authorization: "Bearer " + token } });
      assert.equal(result.statusCode, status, result.body);
      return result.json();
    };
    const header = "sku,name,brand,category,unit,cost,retailPrice,taxPercent,barcodes,hsnSac";
    const line = (sku: string, code: string, price = "12.30") =>
      [sku, '"Air, oil filter"', "Demo", "Filters", "Each", "8.01", price, "18", code, "842123"].join(",");
    const catalog = () => records(db, "demo", "product");
    const count = (await catalog()).length;
    const first = line("IMPORT-01", "036000291452");
    const valid = "\uFEFF" + [header, first, line("IMPORT-02", "PRIVATE-A|PRIVATE-B")].join("\r\n");
    const preview = "products/import/preview";
    const submit = "products/import";
    await post(preview, { csv: valid }, 403, cashier);
    await post(submit, { csv: valid }, 403, cashier);
    await post(preview, { csv: header }, 400);
    await post(preview, { csv: header + ",openingStock\n" + first + ",10" }, 400);
    await post(preview, { csv: header + ",name\n" + first + ",bad" }, 400);
    const checked = await post(preview, { csv: valid });
    assert.equal(checked.valid, true);
    assert.deepEqual(checked.rows[0], { row: 2, sku: "IMPORT-01", name: "Air, oil filter", retailPrice: 1230 });
    assert.equal((await catalog()).length, count);

    const bad = [header, first, line("import01", "OTHER"), line("OTHER", "0036000291452"),
      line("THIRD", "ABC", "1.239"), line("BAD-EAN", "4006381333932")].join("\n");
    const rejected = await post(preview, { csv: bad });
    assert.equal(rejected.valid, false);
    assert.equal(rejected.rows.filter((row: any) => row.error).length, 4);
    await post(submit, { csv: bad, transactionId: randomUUID() }, 409);
    assert.equal((await catalog()).length, count);

    const request = { csv: valid, transactionId: randomUUID() };
    const firstResult = await post(submit, request);
    assert.deepEqual(firstResult, { imported: 2 });
    assert.deepEqual(await post(submit, request), firstResult);
    const loaded = (await catalog()).filter((p) => p.sku.startsWith("IMPORT-")).sort((a, b) => a.sku.localeCompare(b.sku));
    assert.equal(loaded.length, 2);
    assert.equal(loaded[0].cost, 801);
    assert.equal(loaded[0].wholesalePrice, 1230);
    assert.equal(loaded[0].taxRate, 1800);
    assert.equal(loaded[0].barcodes[0], "036000291452");
    assert.deepEqual(loaded[1].barcodes, ["PRIVATE-A", "PRIVATE-B"]);
    assert.equal((await db.query("SELECT 1 FROM stock WHERE organization_id=$1 AND product_id=$2", ["demo", loaded[0].id])).rows.length, 0);
    assert.equal((await post(preview, { csv: valid })).valid, false);
    await post(submit, { csv: valid, transactionId: randomUUID() }, 409);
    await post("products/" + loaded[0].id + "/remove", {});
    assert.ok(await getRecord(db, "demo", "removedProduct", loaded[0].id));
    assert.equal((await post(preview, { csv: header + "\n" + line("NEW-SKU", "0036000291452") })).valid, false);
    const staged = header + "\n" + line("IMPORT-RACE", "PREVIEW-CODE");
    assert.equal((await post(preview, { csv: staged })).valid, true);
    await post("products", { sku: "COMPETING-SKU", name: "Counter entry", brand: "Demo", category: "Filters", unit: "Each", barcodes: ["PREVIEW-CODE"] });
    await post(submit, { csv: staged, transactionId: randomUUID() }, 409);
    assert.ok(!(await catalog()).some((p) => p.sku === "IMPORT-RACE"));
  } finally {
    await app.close();
    await db.close();
  }
});
