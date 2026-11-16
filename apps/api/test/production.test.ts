import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { connectDatabase, migrate, getRecord, records } from "../src/db.js";
import { createApp } from "../src/app.js";
import { bootstrapOwner } from "../src/setup.js";
import { runtimeConfig } from "../src/config.js";
import { fitment } from "../src/domain.js";

test("production configuration, fresh setup, session revocation, proxy limits, tax snapshots and append-only ledger", async () => {
  const environment = { ...process.env };
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  const org = "production-" + randomUUID();
  Object.assign(process.env, {
    NODE_ENV: "production",
    DATABASE_URL:
      process.env.DATABASE_URL || "postgresql://configuration-check-only",
    JWT_SECRET: randomBytes(48).toString("base64url"),
    SEED_DEMO: "false",
    CORS_ORIGINS: "https://pos.example.test",
    TRUST_PROXY_HOPS: "1",
    BOOTSTRAP_ORG_ID: org,
    BOOTSTRAP_ORG_NAME: "Fresh acceptance shop",
    BOOTSTRAP_BRANCH_ID: "main",
    BOOTSTRAP_BRANCH_NAME: "Main counter",
    BOOTSTRAP_CURRENCY: "INR",
    BOOTSTRAP_OWNER_EMAIL: "owner@acceptance.test",
    BOOTSTRAP_OWNER_PASSWORD: randomBytes(24).toString("base64url"),
  });
  let app: Awaited<ReturnType<typeof createApp>> | undefined;
  try {
    const secret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = "development-only-motorline-please-change-secret";
    assert.throws(runtimeConfig, /JWT_SECRET/);
    process.env.JWT_SECRET = secret;
    process.env.SEED_DEMO = "true";
    assert.throws(runtimeConfig, /Demo/);
    process.env.SEED_DEMO = "false";
    await bootstrapOwner(db);
    await bootstrapOwner(db);
    assert.equal((await records(db, org, "user")).length, 1);
    assert.equal((await records(db, org, "product")).length, 0);
    app = await createApp(db);
    const call = async (
      method: string,
      path: string,
      body: any,
      token?: string,
      status = 200,
      ip = "198.51.100.20",
    ) => {
      const response = await app!.inject({
        method: method as any,
        url: "/api/v1/" + path,
        payload: body,
        headers: {
          "x-forwarded-for": ip,
          ...(token ? { authorization: "Bearer " + token } : {}),
        },
      });
      assert.equal(
        response.statusCode,
        status,
        `${method} ${path}: ${response.body}`,
      );
      return response.json();
    };
    const loginBody = {
      organizationId: org,
      email: "owner@acceptance.test",
      password: process.env.BOOTSTRAP_OWNER_PASSWORD,
      branchId: "main",
    };
    const auth = await call("POST", "auth/login", loginBody);
    const token = auth.token;
    for (let attempt = 0; attempt < 10; attempt++)
      await call(
        "POST",
        "auth/login",
        { ...loginBody, password: "wrong" },
        undefined,
        401,
        "198.51.100.21",
      );
    await call(
      "POST",
      "auth/login",
      loginBody,
      undefined,
      429,
      "198.51.100.21",
    );
    await call(
      "POST",
      "auth/login",
      loginBody,
      undefined,
      200,
      "198.51.100.22",
    );
    const user = await call(
      "POST",
      "users",
      {
        name: "Test cashier",
        email: "cashier@acceptance.test",
        password: "InitialCashierPassword!",
        role: "cashier",
        branchIds: ["main"],
      },
      token,
    );
    const cashier = await call("POST", "auth/login", {
      ...loginBody,
      email: user.email,
      password: "InitialCashierPassword!",
    });
    const ownerData = await call("GET", "bootstrap", undefined, token);
    assert.equal(ownerData.users.length, 2);
    assert.ok(ownerData.users.some((entry: any) => entry.id === "owner"));
    assert.ok(!JSON.stringify(ownerData.users).includes("passwordHash"));
    const cashierData = await call(
      "GET",
      "bootstrap",
      undefined,
      cashier.token,
    );
    assert.deepEqual(cashierData.users, []);
    assert.ok(!JSON.stringify(cashierData).includes("passwordHash"));
    await call(
      "POST",
      "users",
      { ...user, password: "UpdatedCashierPassword!" },
      token,
    );
    await call("GET", "bootstrap", undefined, cashier.token, 401);
    await call("POST", "settings", { currency: "JPY" }, token, 400);
    await call(
      "POST",
      "settings",
      {
        currency: "USD",
        taxMode: "inclusive",
        taxDisplayName: "Sales tax",
        receiptFooter: "Original footer\r\nSecond line",
        business: {
          legalName: "Original Legal Company",
          tradingName: "Shop",
          address: "1 Fictional Road\r\nTest City",
          taxRegistrationId: "DEMO-REG",
        },
        branchName: "First branch",
        branchAddress: "2 Fictional Lane\nTest City",
        taxRates: [1800],
      },
      token,
    );
    await call(
      "POST",
      "settings",
      { receiptFooter: "Invalid\u0000control" },
      token,
      400,
    );
    const branch = await call(
      "POST",
      "branches",
      { id: "second", name: "Second branch", address: "3 Fictional Road" },
      token,
    );
    assert.equal(branch.id, "second");
    const bin = await call(
      "POST",
      "locations",
      { area: "Store", rack: "A", shelf: "1", bin: "1", kind: "sellable" },
      token,
    );
    const part = await call(
      "POST",
      "products",
      {
        name: "Inclusive part",
        sku: "INCLUSIVE-1",
        brand: "Demo",
        partNumber: "DEMO-A",
        category: "Parts",
        unit: "Each",
        universal: true,
        cost: 5000,
        retailPrice: 11800,
        wholesalePrice: 11800,
        taxRate: 1800,
        hsnSac: "DEMO-HSN",
      },
      token,
    );
    await call(
      "POST",
      "inventory/adjust",
      {
        productId: part.id,
        binId: bin.id,
        quantity: true,
        reason: "Reject booleans",
      },
      token,
      400,
    );
    await call(
      "POST",
      "inventory/adjust",
      {
        transactionId: randomUUID(),
        productId: part.id,
        binId: bin.id,
        quantity: 5,
        reason: "Opening stock",
      },
      token,
    );
    const shift = await call("POST", "shifts/open", { openingCash: 0 }, token);
    await call("POST", "settings", { currency: "EUR" }, token, 409);
    const snapshot = await call("GET", "bootstrap", undefined, token);
    const device = await call(
      "POST",
      "devices/enroll",
      {
        name: "Counter",
        offlineAllowed: true,
        offlineHours: 24,
        tenders: ["Cash"],
        rangeSize: 100,
      },
      token,
    );
    const body = {
      transactionId: randomUUID(),
      shiftId: shift.id,
      discount: 0,
      lines: [{ productId: part.id, qty: 1, binId: bin.id }],
      tenders: [{ type: "Cash", amount: 11800, confirmed: true }],
    };
    const parked = await call(
      "POST",
      "holds",
      {
        cart: {
          ...body,
          lines: [{ productId: part.id, qty: "2", binId: bin.id }],
        },
      },
      token,
    );
    assert.equal(parked.cart.lines[0].qty, 2);
    assert.equal(
      (await call("GET", "bootstrap", undefined, token)).stock.find(
        (entry: any) => entry.productId === part.id,
      ).reserved,
      2,
    );
    await call("DELETE", `holds/${parked.id}`, undefined, token);
    assert.equal(await getRecord(db, org, "hold", parked.id), undefined);
    const resumed = await call("POST", "holds", { cart: body }, token);
    const sale = await call(
      "POST",
      "invoices",
      { ...body, holdId: resumed.id },
      token,
    );
    assert.equal(sale.total, 11800);
    assert.equal(sale.tax, 1800);
    assert.equal(sale.taxMode, "inclusive");
    assert.equal(sale.business.legalName, "Original Legal Company");
    assert.equal(sale.lines[0].hsnSac, "DEMO-HSN");
    assert.equal(await getRecord(db, org, "hold", resumed.id), undefined);
    assert.equal(
      (await call("GET", "bootstrap", undefined, token)).stock.find(
        (entry: any) => entry.productId === part.id,
      ).reserved,
      0,
    );
    await call(
      "POST",
      "settings",
      {
        taxMode: "exclusive",
        receiptFooter: "New footer",
        business: {
          legalName: "Updated Legal Company",
          address: "Updated address",
        },
        branchName: "Renamed branch",
      },
      token,
    );
    const offline = {
      ...body,
      transactionId: randomUUID(),
      offline: true,
      deviceId: device.id,
      invoiceNumber: device.rangeStart,
      occurredAt: new Date(
        new Date(device.enrolledAt).getTime() - 601,
      ).toISOString(),
      catalogRevision: snapshot.catalogRevision,
    };
    await call(
      "POST",
      "invoices",
      {
        ...offline,
        transactionId: randomUUID(),
        occurredAt: new Date(
          new Date(device.enrolledAt).getTime() - 60001,
        ).toISOString(),
      },
      token,
      403,
    );
    await call(
      "POST",
      "invoices",
      {
        ...offline,
        transactionId: randomUUID(),
        occurredAt: new Date(Date.now() + 360000).toISOString(),
      },
      token,
      403,
    );
    await call(
      "POST",
      "invoices",
      {
        ...offline,
        transactionId: randomUUID(),
        occurredAt: new Date(
          new Date(device.offlineUntil).getTime() + 1,
        ).toISOString(),
      },
      token,
      403,
    );
    const synced = await call(
      "POST",
      "sync",
      { deviceId: device.id, transactions: [offline] },
      token,
    );
    assert.equal(synced.results[0].status, "accepted");
    assert.equal(synced.results[0].invoice.total, 11800);
    assert.equal(
      synced.results[0].invoice.business.legalName,
      "Original Legal Company",
    );
    const current = await call(
      "POST",
      "invoices",
      {
        ...body,
        transactionId: randomUUID(),
        tenders: [{ type: "Cash", amount: 13924, confirmed: true }],
      },
      token,
    );
    assert.equal(current.total, 13924);
    assert.equal(current.business.legalName, "Updated Legal Company");
    const credit = await call(
      "POST",
      `invoices/${sale.id}/returns`,
      {
        transactionId: randomUUID(),
        reason: "Return",
        condition: "sellable",
        lines: [{ lineId: sale.lines[0].id, quantity: 1, binId: bin.id }],
      },
      token,
    );
    assert.equal(credit.total, 11800);
    assert.equal(credit.taxMode, "inclusive");
    assert.equal(credit.business.legalName, "Original Legal Company");
    assert.equal(credit.receiptFooter, "Original footer\nSecond line");
    assert.equal(credit.business.address, "1 Fictional Road\nTest City");
    await call(
      "POST",
      "invoices",
      {
        ...body,
        transactionId: randomUUID(),
        tenders: [
          { type: "Card", amount: 13924, confirmed: true, reference: "" },
        ],
      },
      token,
      400,
    );
    await call("POST", "settings", { tenderTypes: ["Cash"] }, token);
    await call(
      "POST",
      "invoices",
      {
        ...body,
        transactionId: randomUUID(),
        tenders: [
          {
            type: "Card",
            amount: 13924,
            confirmed: true,
            reference: "external-reference",
          },
        ],
      },
      token,
      400,
    );
    const movement = (
      await db.query(
        "SELECT id FROM stock_ledger WHERE organization_id=$1 LIMIT 1",
        [org],
      )
    ).rows[0];
    await assert.rejects(
      db.query("UPDATE stock_ledger SET quantity=999 WHERE id=$1", [
        movement.id,
      ]),
      /append-only/,
    );
    await assert.rejects(
      db.query("DELETE FROM transactions WHERE organization_id=$1", [org]),
      /append-only/,
    );
    await migrate(db);
    assert.equal((await getRecord(db, org, "invoice", sale.id))?.total, 11800);
    const report = await call("GET", "reports/sales", undefined, token);
    assert.equal(report.totals.gross, 11800 + 11800 + 13924);
    assert.equal(report.totals.net, 11800 + 13924);
    const datedPart = {
      fitments: [
        {
          make: "Test",
          model: "One",
          yearFrom: 2020,
          yearTo: 2030,
          effectiveFrom: "2025-01-01",
          effectiveTo: "2025-12-31",
        },
      ],
    };
    assert.equal(
      fitment(
        datedPart,
        { make: "Test", model: "One", year: 2025 },
        "2025-06-01",
      ).status,
      "compatible",
    );
    assert.equal(
      fitment(
        datedPart,
        { make: "Test", model: "One", year: 2025 },
        "2026-01-01",
      ).status,
      "unverified",
    );
    // A separate INR organization exercises domestic GST without mixing accounting currencies.
    const gstOrg = "gst-" + randomUUID();
    Object.assign(process.env, {
      BOOTSTRAP_ORG_ID: gstOrg,
      BOOTSTRAP_BRANCH_ID: "p1",
      BOOTSTRAP_CURRENCY: "INR",
    });
    await bootstrapOwner(db);
    const gstAuth = await call("POST", "auth/login", {
      ...loginBody,
      organizationId: gstOrg,
      branchId: "p1",
    });
    const gstToken = gstAuth.token;
    const gstSettings = {
      taxScheme: "india-gst",
      taxMode: "exclusive",
      invoicePrefix: "INV",
      creditNotePrefix: "CR",
      business: {
        legalName: "GST Test Company",
        address: "Test Street\nTest City",
        stateCode: "27",
        taxRegistrationId: "27ABCDE1234F1Z5",
      },
      branchStateCode: "27",
    };
    await call(
      "POST",
      "settings",
      {
        ...gstSettings,
        business: {
          ...gstSettings.business,
          taxRegistrationId: "29ABCDE1234F1Z5",
        },
      },
      gstToken,
      400,
    );
    await call("POST", "settings", gstSettings, gstToken);
    await call(
      "POST",
      "settings",
      { invoicePrefix: "THIS-PREFIX-IS-LONG" },
      gstToken,
      400,
    );
    await call(
      "POST",
      "branches",
      { id: "d1", name: "Different registration state", stateCode: "29" },
      gstToken,
      400,
    );
    const gstShift = await call(
      "POST",
      "shifts/open",
      { openingCash: 0 },
      gstToken,
    );
    const service = await call(
      "POST",
      "products",
      {
        name: "GST test service",
        sku: "GST-SERVICE",
        brand: "Test",
        partNumber: "SERVICE",
        category: "Service",
        unit: "Each",
        universal: true,
        type: "service",
        cost: 0,
        retailPrice: 9,
        wholesalePrice: 9,
        taxRate: 1800,
        hsnSac: "998714",
      },
      gstToken,
    );
    const gstBody = {
      transactionId: randomUUID(),
      shiftId: gstShift.id,
      discount: 0,
      placeOfSupply: "27",
      lines: [{ productId: service.id, qty: 3, binId: "" }],
      tenders: [{ type: "Cash", amount: 32, confirmed: true }],
    };
    await call(
      "POST",
      "invoices",
      { ...gstBody, placeOfSupply: "" },
      gstToken,
      400,
    );
    const gstSale = await call("POST", "invoices", gstBody, gstToken);
    assert.equal(gstSale.total, 32);
    assert.equal(gstSale.tax, 5);
    assert.deepEqual(gstSale.taxComponents, [
      { name: "CGST", amount: 3 },
      { name: "SGST", amount: 2 },
    ]);
    const inter = await call(
      "POST",
      "invoices",
      { ...gstBody, transactionId: randomUUID(), placeOfSupply: "29" },
      gstToken,
    );
    assert.deepEqual(inter.taxComponents, [{ name: "IGST", amount: 5 }]);
    const customer = await call(
      "POST",
      "customers",
      {
        name: "Registered test customer",
        email: "gst@acceptance.test",
        address: "Customer Street\nCustomer City",
        stateCode: "29",
        taxRegistrationId: "29ABCDE1234F1Z5",
      },
      gstToken,
    );
    const gstSnapshot = await call("GET", "bootstrap", undefined, gstToken);
    const gstDevice = await call(
      "POST",
      "devices/enroll",
      {
        name: "GST offline counter",
        offlineAllowed: true,
        offlineHours: 24,
        tenders: ["Cash"],
        rangeSize: 100,
      },
      gstToken,
    );
    await call(
      "POST",
      "customers",
      { ...customer, stateCode: "27", taxRegistrationId: "27ABCDE1234F1Z5" },
      gstToken,
    );
    const gstOffline = await call(
      "POST",
      "sync",
      {
        deviceId: gstDevice.id,
        transactions: [
          {
            ...gstBody,
            transactionId: randomUUID(),
            customerId: customer.id,
            placeOfSupply: "",
            offline: true,
            deviceId: gstDevice.id,
            invoiceNumber: gstDevice.rangeStart,
            occurredAt: new Date().toISOString(),
            catalogRevision: gstSnapshot.catalogRevision,
          },
        ],
      },
      gstToken,
    );
    assert.equal(gstOffline.results[0].status, "accepted");
    assert.equal(gstOffline.results[0].invoice.customer.stateCode, "29");
    assert.deepEqual(gstOffline.results[0].invoice.taxComponents, [
      { name: "IGST", amount: 5 },
    ]);
    await call(
      "POST",
      "settings",
      {
        taxScheme: "general",
        business: { legalName: "Renamed after GST sale" },
      },
      gstToken,
    );
    const credits = [];
    for (let quantity = 0; quantity < 3; quantity++)
      credits.push(
        await call(
          "POST",
          `invoices/${gstSale.id}/returns`,
          {
            transactionId: randomUUID(),
            reason: "Partial service correction",
            condition: "sellable",
            lines: [{ lineId: gstSale.lines[0].id, quantity: 1 }],
          },
          gstToken,
        ),
      );
    assert.equal(
      credits.reduce((sum, item) => sum + item.total, 0),
      32,
    );
    assert.equal(
      credits.reduce((sum, item) => sum + item.tax, 0),
      5,
    );
    assert.equal(
      credits.reduce(
        (sum, item) =>
          sum +
          item.taxComponents.find((part: any) => part.name === "CGST").amount,
        0,
      ),
      3,
    );
    assert.equal(
      credits.reduce(
        (sum, item) =>
          sum +
          item.taxComponents.find((part: any) => part.name === "SGST").amount,
        0,
      ),
      2,
    );
    for (const item of credits) {
      assert.equal(item.taxScheme, "india-gst");
      assert.equal(item.business.legalName, "GST Test Company");
      assert.equal(item.invoiceNumber, gstSale.number);
      assert.match(item.number, /^[A-Za-z0-9/-]{1,16}$/);
      assert.equal(
        item.taxComponents.reduce(
          (sum: number, part: any) => sum + part.amount,
          0,
        ),
        item.tax,
      );
    }
    const gstReport = await call("GET", "reports/tax", undefined, gstToken);
    assert.equal(gstReport.totals.tax, 10);
    assert.equal(
      gstReport.rows.reduce(
        (sum: number, row: any) =>
          sum +
          row.taxComponents.reduce(
            (n: number, part: any) => n + part.amount,
            0,
          ),
        0,
      ),
      10,
    );
    console.log(
      "PASS production defaults, empty owner bootstrap, per-forwarded-client login rate limit, password token revocation, strict numeric validation, configurable inclusive/exclusive taxes, immutable business/branch/receipt and offline settings snapshots, tender controls, append-only stock and idempotency ledgers",
    );
  } finally {
    await app?.close();
    await db.close();
    for (const key of Object.keys(process.env))
      if (!(key in environment)) delete process.env[key];
    Object.assign(process.env, environment);
  }
});
