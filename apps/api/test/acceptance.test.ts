import { test } from "node:test";
import assert from "node:assert/strict";
import {
  connectDatabase,
  migrate,
  getRecord,
  records,
  putRecord,
} from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { randomUUID } from "node:crypto";
import jwt from "jsonwebtoken";
import { bootstrapOwner } from "../src/setup.js";

test("retail acceptance, permissions, idempotency, conflict reconciliation and immutable ledgers", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    const call = async (
      method: string,
      path: string,
      body: any,
      token?: string,
      status = 200,
    ) => {
      const response = await app.inject({
        method: method as any,
        url: "/api/v1/" + path,
        payload: body,
        headers: token ? { authorization: "Bearer " + token } : {},
      });
      assert.equal(
        response.statusCode,
        status,
        `${method} ${path}: ${response.body}`,
      );
      return response.json();
    };
    const owner = await call("POST", "auth/login", {
      email: "owner@motorline.local",
      password: "MotorlineDemo123!",
    });
    const cashier = await call("POST", "auth/login", {
      email: "cashier@motorline.local",
      password: "MotorlineDemo123!",
    });
    await call(
      "POST",
      "auth/login",
      {
        email: "cashier@motorline.local",
        password: "MotorlineDemo123!",
        branchId: "mumbai",
      },
      undefined,
      403,
    );
    const tok = owner.token;
    const bootstrap = await call("GET", "bootstrap", undefined, tok);
    assert.equal(bootstrap.products.length, 12);
    await migrate(db);
    assert.equal((await records(db, "demo", "product")).length, 12);
    const part = await call(
      "POST",
      "products",
      {
        name: "Acceptance filter",
        sku: "ACCEPT-" + randomUUID(),
        brand: "Fictional",
        partNumber: "FL 100-A",
        category: "Filters",
        unit: "Each",
        barcodes: ["ACCEPT-" + randomUUID()],
        cost: 10000,
        retailPrice: 20000,
        wholesalePrice: 18000,
        taxRate: 1800,
        fitments: [
          {
            make: "Demo",
            model: "One",
            yearFrom: 2020,
            yearTo: 2025,
            engine: "1.0L",
            fuel: "Petrol",
            source: "Fictional",
          },
        ],
      },
      tok,
    );
    await call(
      "POST",
      "products",
      { ...part, name: "Unauthorized" },
      cashier.token,
      403,
    );
    const po = await call(
      "POST",
      "purchase-orders",
      {
        supplierId: "supplier-1",
        lines: [{ productId: part.id, quantity: 10, cost: 10000 }],
      },
      tok,
    );
    const receipt = {
      transactionId: randomUUID(),
      landedCost: 1000,
      lines: [{ productId: part.id, quantity: 6, binId: "bin-a1" }],
    };
    await call("POST", `purchase-orders/${po.id}/receive`, receipt, tok);
    await call("POST", `purchase-orders/${po.id}/receive`, receipt, tok);
    await call(
      "POST",
      `purchase-orders/${po.id}/receive`,
      {
        transactionId: randomUUID(),
        landedCost: 0,
        lines: [{ productId: part.id, quantity: 4, binId: "bin-a2" }],
      },
      tok,
    );
    await call(
      "POST",
      "inventory/move",
      {
        productId: part.id,
        fromBinId: "bin-a1",
        toBinId: "bin-b1",
        quantity: 2,
        reason: "Shelf change",
      },
      tok,
    );
    const after = await call("GET", "bootstrap", undefined, tok);
    assert.equal(
      after.stock.find(
        (stock: any) => stock.productId === part.id && stock.binId === "bin-b1",
      ).quantity,
      2,
    );
    assert.equal(
      after.purchaseOrders.find((order: any) => order.id === po.id).status,
      "received",
    );
    const shift = await call(
      "POST",
      "shifts/open",
      { openingCash: 50000 },
      tok,
    );
    const vehicle = {
      make: "Demo",
      model: "One",
      year: 2022,
      engine: "1.0L",
      fuel: "Petrol",
    };
    assert.equal(
      (
        await call(
          "POST",
          "fitments/check",
          { productId: part.id, vehicle },
          tok,
        )
      ).status,
      "compatible",
    );
    assert.equal(
      (
        await call(
          "POST",
          "fitments/check",
          { productId: part.id, vehicle: { ...vehicle, model: "Two" } },
          tok,
        )
      ).status,
      "incompatible",
    );
    assert.equal(
      (
        await call(
          "POST",
          "fitments/check",
          {
            productId: part.id,
            vehicle: { make: "Demo", model: "One", year: 2022 },
          },
          tok,
        )
      ).status,
      "unverified",
    );
    const saleBody = {
      transactionId: randomUUID(),
      shiftId: shift.id,
      vehicle,
      priceLevel: "retail",
      discount: 1,
      discountReason: "Rounding test",
      lines: [{ productId: part.id, qty: 2, binId: "bin-b1" }],
      tenders: [{ type: "Cash", amount: 50000, confirmed: true }],
    };
    await call("POST", "invoices", { ...saleBody, expectedTotal: 47200 }, tok, 409);
    const sale = await call("POST", "invoices", saleBody, tok);
    assert.equal(sale.total, 47199);
    const repeat = await call("POST", "invoices", saleBody, tok);
    assert.equal(repeat.id, sale.id);
    await call("POST", "invoices", { ...saleBody, discount: 2 }, tok, 409);
    const totalBefore = (await records(db, "demo", "invoice")).length;
    await assert.rejects(
      db.query(
        "UPDATE records SET data=$1 WHERE organization_id=$2 AND kind=$3 AND id=$4",
        [JSON.stringify({ ...sale, total: 1 }), "demo", "invoice", sale.id],
      ),
      /immutable/,
    );
    const returned = await call(
      "POST",
      `invoices/${sale.id}/returns`,
      {
        transactionId: randomUUID(),
        reason: "Wrong fitment part",
        condition: "damaged",
        lines: [
          { lineId: sale.lines[0].id, quantity: 1, binId: "bin-damaged" },
        ],
        refundType: "Cash",
      },
      tok,
    );
    const returned2 = await call(
      "POST",
      `invoices/${sale.id}/returns`,
      {
        transactionId: randomUUID(),
        reason: "Other unit returned",
        condition: "sellable",
        lines: [{ lineId: sale.lines[0].id, quantity: 1, binId: "bin-a1" }],
        refundType: "Cash",
      },
      tok,
    );
    assert.equal(returned.total + returned2.total, sale.total);
    await call("POST", "products", { id: part.id, category: "Reclassified" }, tok);
    const margins = await call("GET", "reports/margin?category=Filters&sku=" + part.sku, undefined, tok);
    assert.equal(margins.rows.length, 3);
    assert.equal(margins.rows.reduce((sum: number, row: any) => sum + row.margin, 0), margins.totals.margin);
    assert.equal(margins.totals.margin, 0);
    await call(
      "POST",
      `invoices/${sale.id}/returns`,
      {
        transactionId: randomUUID(),
        reason: "Too many",
        condition: "sellable",
        lines: [{ lineId: sale.lines[0].id, quantity: 1, binId: "bin-a1" }],
      },
      tok,
      400,
    );
    const device = await call(
      "POST",
      "devices/enroll",
      {
        name: "Acceptance Counter",
        offlineAllowed: true,
        offlineHours: 24,
        tenders: ["Cash"],
        rangeSize: 1000,
      },
      tok,
    );
    const latest = await call("GET", "bootstrap", undefined, tok);
    const offline = {
      transactionId: randomUUID(),
      deviceId: device.id,
      invoiceNumber: device.rangeStart,
      offline: true,
      occurredAt: new Date().toISOString(),
      catalogRevision: latest.catalogRevision,
      shiftId: shift.id,
      vehicle,
      priceLevel: "retail",
      discount: 0,
      lines: [{ productId: part.id, qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 23600, confirmed: true }],
    };
    await call("POST", "products", { ...part, retailPrice: 21000 }, tok);
    const sync = await call(
      "POST",
      "sync",
      { deviceId: device.id, transactions: [offline] },
      tok,
    );
    assert.equal(sync.results[0].status, "accepted");
    assert.equal(sync.results[0].invoice.total, 23600);
    const retry = await call(
      "POST",
      "sync",
      { deviceId: device.id, transactions: [offline] },
      tok,
    );
    assert.equal(retry.results[0].invoice.id, sync.results[0].invoice.id);
    assert.equal(
      (await records(db, "demo", "invoice")).length,
      totalBefore + 1,
    );
    const state = await call("GET", "bootstrap", undefined, tok);
    const bin = state.stock.find(
      (entry: any) => entry.productId === part.id && entry.binId === "bin-a2",
    );
    await call(
      "POST",
      "inventory/adjust",
      {
        productId: part.id,
        binId: "bin-a2",
        quantity: 1 - bin.quantity,
        reason: "Last-unit scenario",
      },
      tok,
    );
    const first = {
      ...offline,
      transactionId: randomUUID(),
      invoiceNumber: device.rangeStart + 1,
      lines: [{ productId: part.id, qty: 1, binId: "bin-a2" }],
    };
    const second = {
      ...first,
      transactionId: randomUUID(),
      invoiceNumber: device.rangeStart + 2,
    };
    const outcomes = await Promise.all([
      call("POST", "sync", { deviceId: device.id, transactions: [first] }, tok),
      call(
        "POST",
        "sync",
        { deviceId: device.id, transactions: [second] },
        tok,
      ),
    ]);
    assert.deepEqual(
      outcomes.map((result) => result.results[0].status).sort(),
      ["accepted", "conflict"],
    );
    const conflict = outcomes
      .flatMap((result) => result.results)
      .find((result) => result.status === "conflict");
    const resolved = await call(
      "POST",
      `conflicts/${conflict.conflictId}/resolve`,
      {
        action: "accept",
        reason: "Physical count confirms oversold item. Replenishment ordered.",
      },
      tok,
    );
    assert.equal(resolved.status, "accepted");
    await call(
      "POST",
      `conflicts/${conflict.conflictId}/resolve`,
      { action: "accept", reason: "Retry" },
      tok,
    );
    const final = await call("GET", "bootstrap", undefined, tok);
    assert.equal(
      final.stock.find(
        (entry: any) => entry.productId === part.id && entry.binId === "bin-a2",
      ).quantity,
      -1,
    );
    const salesReport = await call("GET", "reports/sales", undefined, tok);
    assert.equal(
      salesReport.totals.net,
      salesReport.totals.gross - salesReport.totals.returns,
    );
    const daily = await call("GET", "reports/daily-sales", undefined, tok);
    assert.equal(daily.rows.reduce((sum: number, row: any) => sum + row.net, 0), salesReport.totals.net);
    const tender = await call("GET", "reports/tenders", undefined, tok);
    assert.equal(tender.rows.reduce((sum: number, row: any) => sum + row.net, 0), tender.totals.net);
    assert.equal(tender.totals.net, salesReport.totals.net);
    await call("GET", "reports/tenders?category=Filters", undefined, tok, 400);
    await call("GET", "reports/sales?dateFrom=2025-02-30", undefined, tok, 400);
    await putRecord(db, "demo", "invoice", {
      ...final.invoices[0], id: "report-boundary-fixture", createdAt: "2025-01-01T19:00:00Z",
    }, "pune");
    const boundary = await call("GET", "reports/daily-sales?dateFrom=2025-01-02&dateTo=2025-01-02", undefined, tok);
    assert.equal(boundary.timeZone, "Asia/Kolkata");
    assert.equal(boundary.rows[0].day, "2025-01-02");
    await call("POST", "products", { ...part, id: undefined, sku: "UPC-FIXTURE", barcodes: ["036000291452"] }, tok);
    await call("POST", "products", { ...part, id: undefined, sku: "EAN-FIXTURE", barcodes: ["0036000291452"] }, tok, 409);
    for (const report of [
      "returns",
      "discounts",
      "margin",
      "shifts",
      "tenders",
      "valuation",
      "stock-by-bin",
      "stock-movement",
      "low-stock",
      "fast-moving",
      "slow-moving",
      "aging",
      "purchase-receipts",
      "tax",
      "warranty",
      "cores",
      "fitment",
    ])
      await call("GET", `reports/${report}`, undefined, tok);
    await call("GET", "reports/sales", undefined, cashier.token, 403);
    const csv = `productId,make,model,yearFrom,yearTo,engine,fuel,source\n${part.id},Demo,New,2020,2025,2.0L,Diesel,Manual`;
    const preview = await call("POST", "fitments/import/preview", { csv }, tok);
    assert.equal(preview.valid, true);
    assert.equal(
      (
        await call(
          "POST",
          "fitments/import",
          { csv, duplicateHandling: "skip" },
          tok,
        )
      ).imported,
      1,
    );
    assert.equal(
      (
        await call(
          "POST",
          "fitments/import",
          { csv, duplicateHandling: "skip" },
          tok,
        )
      ).skipped,
      1,
    );
    const invalid = await call(
      "POST",
      "fitments/import/preview",
      {
        csv: "productId,make,model,yearFrom,yearTo,source\nmissing,Demo,One,2025,2020,Manual",
      },
      tok,
    );
    assert.equal(invalid.valid, false);
    const current = await getRecord(db, "demo", "product", part.id);
    assert.equal(current?.retailPrice, 21000);
    assert.equal(sale.lines[0].unitPrice, 20000);
    const cashierData = await call(
      "GET",
      "bootstrap",
      undefined,
      cashier.token,
    );
    assert.equal(cashierData.products[0].cost, undefined);
    const cashierShift = await call(
      "POST",
      "shifts/open",
      { openingCash: 0 },
      cashier.token,
    );
    const incompatible = {
      transactionId: randomUUID(),
      shiftId: cashierShift.id,
      vehicle: { ...vehicle, model: "Incompatible" },
      discount: 0,
      lines: [
        {
          productId: part.id,
          qty: 1,
          binId: "bin-a1",
          overrideReason: "Customer confirmed custom conversion",
        },
      ],
      tenders: [{ type: "Cash", amount: 24780, confirmed: true }],
    };
    await call("POST", "invoices", incompatible, cashier.token, 403);
    const approval = await call(
      "POST",
      "approvals",
      {
        action: "fitment",
        transactionId: incompatible.transactionId,
        reason: "Inspected conversion",
      },
      tok,
    );
    const approvedSale = await call(
      "POST",
      "invoices",
      { ...incompatible, approvalId: approval.id },
      cashier.token,
    );
    assert.equal(approvedSale.lines[0].fitment.status, "incompatible");
    const serialized = await call(
      "POST",
      "products",
      {
        name: "Tracked exchange unit",
        sku: "SER-" + randomUUID(),
        brand: "Demo",
        partNumber: "S-1",
        category: "Electrical",
        unit: "Each",
        cost: 10000,
        retailPrice: 20000,
        wholesalePrice: 19000,
        taxRate: 1800,
        serialTracked: true,
        universal: true,
        coreCharge: 5000,
      },
      tok,
    );
    const spo = await call(
      "POST",
      "purchase-orders",
      {
        supplierId: "supplier-1",
        lines: [{ productId: serialized.id, quantity: 2, cost: 10000 }],
      },
      tok,
    );
    await call(
      "POST",
      `purchase-orders/${spo.id}/receive`,
      {
        transactionId: randomUUID(),
        lines: [
          {
            productId: serialized.id,
            quantity: 2,
            binId: "bin-a1",
            serials: ["SER-001", "SER-002"],
          },
        ],
      },
      tok,
    );
    await call(
      "POST",
      "inventory/move",
      {
        productId: serialized.id,
        fromBinId: "bin-a1",
        toBinId: "bin-b1",
        quantity: 1,
        serials: ["SER-001"],
        reason: "Pick face",
      },
      tok,
    );
    const serialSale = await call(
      "POST",
      "invoices",
      {
        transactionId: randomUUID(),
        shiftId: shift.id,
        discount: 0,
        lines: [
          {
            productId: serialized.id,
            qty: 1,
            binId: "bin-b1",
            serials: ["SER-001"],
          },
        ],
        tenders: [{ type: "Cash", amount: 28600, confirmed: true }],
      },
      tok,
    );
    const serialReturn = await call(
      "POST",
      `invoices/${serialSale.id}/returns`,
      {
        transactionId: randomUUID(),
        reason: "Unused",
        condition: "sellable",
        lines: [
          {
            lineId: serialSale.lines[0].id,
            quantity: 1,
            binId: "bin-a2",
            serials: ["SER-001"],
          },
        ],
        refundType: "Cash",
      },
      tok,
    );
    assert.equal(serialReturn.total, 23600);
    assert.equal(
      (await getRecord(db, "demo", "serial", serialized.id + ":SER-001"))
        ?.status,
      "available",
    );
    const coreBody = {
      transactionId: randomUUID(),
      invoiceId: serialSale.id,
      productId: serialized.id,
      quantity: 1,
      reason: "Old exchange core received",
      refundType: "Cash",
    };
    const core = await call("POST", "core-returns", coreBody, tok);
    assert.equal(core.total, 5000);
    assert.equal(
      (await call("POST", "core-returns", coreBody, tok)).id,
      core.id,
    );
    const transfer = await call(
      "POST",
      "transfers",
      {
        destinationBranchId: "mumbai",
        reason: "Branch stock",
        lines: [
          {
            productId: serialized.id,
            quantity: 1,
            binId: "bin-a1",
            serials: ["SER-002"],
          },
        ],
      },
      tok,
    );
    const destination = await call("POST", "auth/login", {
      email: "owner@motorline.local",
      password: "MotorlineDemo123!",
      branchId: "mumbai",
    });
    const received = await call(
      "POST",
      `transfers/${transfer.id}/receive`,
      {
        lines: [
          {
            productId: serialized.id,
            quantity: 1,
            binId: "mumbai-a1",
            serials: ["SER-002"],
          },
        ],
      },
      destination.token,
    );
    assert.equal(received.status, "received");
    assert.equal(
      (await getRecord(db, "demo", "serial", serialized.id + ":SER-002"))
        ?.branchId,
      "mumbai",
    );
    const reconciled = await call("GET", "reports/sales", undefined, tok);
    assert.equal(
      reconciled.totals.net,
      reconciled.totals.gross -
        reconciled.totals.returns -
        reconciled.totals.coreReturns,
    );
    const combinedSale = await call(
      "POST",
      "invoices",
      {
        transactionId: randomUUID(),
        shiftId: shift.id,
        discount: 0,
        lines: [
          {
            productId: serialized.id,
            qty: 1,
            binId: "bin-a2",
            serials: ["SER-001"],
          },
          { productId: "service", qty: 1 },
        ],
        tenders: [{ type: "Cash", amount: 90000, confirmed: true }],
      },
      tok,
    );
    const voidBody = {
      transactionId: randomUUID(),
      reason: "Accidental invoice entry",
      refundType: "Cash",
    };
    const voided = await call(
      "POST",
      `invoices/${combinedSale.id}/void`,
      voidBody,
      tok,
    );
    assert.equal(voided.totalRefund, combinedSale.total);
    assert.equal(voided.coreRefundTotal, 5000);
    assert.equal(
      (await call("POST", `invoices/${combinedSale.id}/void`, voidBody, tok))
        .id,
      voided.id,
    );
    assert.equal(
      (await getRecord(db, "demo", "serial", serialized.id + ":SER-001"))
        ?.status,
      "available",
    );
    await call(
      "POST",
      "core-returns",
      {
        transactionId: randomUUID(),
        invoiceId: combinedSale.id,
        productId: serialized.id,
        quantity: 1,
        reason: "Cannot refund again",
      },
      tok,
      400,
    );
    await call("POST", "settings", { roundingIncrement: 100 }, tok);
    const rounded = await call(
      "POST",
      "invoices",
      {
        transactionId: randomUUID(),
        shiftId: shift.id,
        vehicle,
        discount: 0,
        lines: [{ productId: part.id, qty: 1, binId: "bin-a1" }],
        tenders: [{ type: "Cash", amount: 30000, confirmed: true }],
      },
      tok,
    );
    assert.equal(rounded.total, 24800);
    assert.equal(
      rounded.lines.reduce((sum: number, line: any) => sum + line.total, 0),
      rounded.total,
    );
    const roundedReturn = await call(
      "POST",
      `invoices/${rounded.id}/returns`,
      {
        transactionId: randomUUID(),
        reason: "Rounded invoice refund",
        condition: "sellable",
        lines: [{ lineId: rounded.lines[0].id, quantity: 1, binId: "bin-a1" }],
      },
      tok,
    );
    assert.equal(roundedReturn.total, rounded.total);
    const config = (await getRecord(db, "demo", "settings", "settings"))!;
    config.nextInvoice = device.rangeStart;
    await putRecord(db, "demo", "settings", config);
    const afterRange = await call(
      "POST",
      "invoices",
      {
        transactionId: randomUUID(),
        shiftId: shift.id,
        discount: 0,
        lines: [{ productId: "service", qty: 1 }],
        tenders: [{ type: "Cash", amount: 60000, confirmed: true }],
      },
      tok,
    );
    assert.ok(afterRange.invoiceNumber > device.rangeEnd);
    const oldToken = jwt.sign(
      {
        sub: "user-owner",
        organizationId: "demo",
        branchId: "pune",
        iat: Math.floor(Date.now() / 1000) - 7200,
      },
      process.env.JWT_SECRET ||
        "development-only-motorline-please-change-secret",
      { expiresIn: 28800 },
    );
    await call("POST", "settings", { sessionHours: 1 }, tok);
    await call("GET", "bootstrap", undefined, oldToken, 401);
    const bootstrapOrg = "setup-" + randomUUID();
    Object.assign(process.env, {
      BOOTSTRAP_ORG_ID: bootstrapOrg,
      BOOTSTRAP_OWNER_PASSWORD: "NewShopOwnerPassword123!",
      BOOTSTRAP_OWNER_EMAIL: "first@shop.test",
      BOOTSTRAP_BRANCH_ID: "main",
    });
    await bootstrapOwner(db);
    await bootstrapOwner(db);
    const firstLogin = await call("POST", "auth/login", {
      organizationId: bootstrapOrg,
      email: "first@shop.test",
      password: "NewShopOwnerPassword123!",
      branchId: "main",
    });
    assert.equal(firstLogin.user.role, "owner");
    assert.equal((await records(db, bootstrapOrg, "user")).length, 1);
    for (const key of [
      "BOOTSTRAP_ORG_ID",
      "BOOTSTRAP_OWNER_PASSWORD",
      "BOOTSTRAP_OWNER_EMAIL",
      "BOOTSTRAP_BRANCH_ID",
    ])
      delete process.env[key];
    console.log(
      "PASS create/receive two bins/move/sale/fitment/returns, exact money, ledger immutability, role+branch protection, migration preservation, CSV preview+duplicates, all reports, offline catalog snapshot+idempotency+concurrent-last-unit+manager resolution",
    );
  } finally {
    await app.close();
    await db.close();
  }
});

test("a sale without a vehicle needs no fitment override, a mismatched vehicle still does", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
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
    const { token } = await call("auth/login", {
      email: "cashier@motorline.local",
      password: "MotorlineDemo123!",
    });
    const shift = await call("shifts/open", { openingCash: 0 }, token);
    assert.equal((await call("fitments/check", { productId: "filter" }, token)).status, "unchecked");
    const sale = (vehicle?: any) => ({
      transactionId: randomUUID(),
      shiftId: shift.id,
      ...(vehicle ? { vehicle } : {}),
      lines: [{ productId: "filter", qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Cash", amount: 100000, confirmed: true }],
    });
    const invoice = await call("invoices", sale(), token);
    assert.equal(invoice.lines[0].fitment.status, "unchecked");
    assert.equal(invoice.lines[0].overrideReason, "");
    await call("invoices", sale({ make: "Other", model: "Car", year: 2022 }), token, 400);
  } finally {
    await app.close();
    await db.close();
  }
});

test("the owner saves one label design for the shop; others cannot change it", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
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
    const login = async (email: string) =>
      (await call("auth/login", { email, password: "MotorlineDemo123!" })).token;
    const owner = await login("owner@motorline.local");
    const design = { widthMm: 38, heightMm: 25, columns: 2, brand: true, price: "mrp", extra: "Ph 98765" };
    const saved = await call("settings", { labelLayout: design }, owner);
    assert.deepEqual(saved.labelLayout, {
      widthMm: 38, heightMm: 25, columns: 2, gapMm: 2, shopName: false, name: true, brand: true,
      partNumber: false, sku: true, bin: false, digits: true, price: "mrp", sizes: {},
      positions: {}, barcodeWidth: "auto", barcodeHeight: "auto", extra: "Ph 98765",
    });
    const moved = await call("settings", {
      labelLayout: { ...design, sizes: { shop: "xlarge" }, positions: { price: { x: 2, y: 3.25 } } },
    }, owner);
    assert.deepEqual(moved.labelLayout.sizes, { shop: "xlarge" });
    assert.deepEqual(moved.labelLayout.positions, { price: { x: 2, y: 3.3 } });
    const legacy = await call("settings", { labelLayout: { nameSize: "large" } }, owner);
    assert.deepEqual(legacy.labelLayout.sizes, { name: "large" });
    await call("settings", { labelLayout: { sizes: { shop: "huge" } } }, owner, 400);
    const sized = await call("settings", { labelLayout: { barcodeWidth: "small", barcodeHeight: "large" } }, owner);
    assert.equal(sized.labelLayout.barcodeWidth, "small");
    assert.equal(sized.labelLayout.barcodeHeight, "large");
    await call("settings", { labelLayout: { barcodeWidth: "giant" } }, owner, 400);
    await call("settings", { labelLayout: { sizes: { logo: "large" } } }, owner, 400);
    await call("settings", { labelLayout: { positions: { price: { x: 500, y: 1 } } } }, owner, 400);
    await call("settings", { labelLayout: { columns: 5 } }, owner, 400);
    await call("settings", { labelLayout: { price: "free" } }, owner, 400);
    await call("settings", { labelLayout: { logo: true } }, owner, 400);
    await call("settings", { labelLayout: design }, await login("manager@motorline.local"), 403);
  } finally {
    await app.close();
    await db.close();
  }
});
