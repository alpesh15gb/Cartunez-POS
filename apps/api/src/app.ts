import Fastify from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import jwt from "jsonwebtoken";
import { createHash } from "node:crypto";
import { parse } from "csv-parse/sync";
import type { Database } from "./db.js";
import { records, getRecord, putRecord } from "./db.js";
import {
  type Actor,
  allow,
  scoped,
  integer,
  text,
  multiline,
  fail,
  id,
  now,
  hashPassword,
  validPassword,
  adjust,
  audit,
  inventory,
  fitment,
  approved,
  idempotent,
  normalize,
  barcodeKey,
  roundRatio,
} from "./domain.js";
import { finalizeSale, returnInvoice } from "./sales.js";
import { report } from "./reports.js";
import { runtimeConfig } from "./config.js";
import {
  currencyCode,
  emailAddress,
  businessProfile,
  invoiceProfile,
  gstProfile,
  documentNumber,
} from "./settings.js";

const roles = ["owner", "manager", "cashier", "inventory"];
const permittedOrigins = [
  "http://localhost:3000",
  "http://127.0.0.1:3000",
  "https://localhost",
  "http://localhost",
  "capacitor://localhost",
  "motorline://app",
];
export async function createApp(db: Database) {
  const configuration = runtimeConfig();
  const app = Fastify({
    logger: process.env.LOG_LEVEL
      ? {
          level: process.env.LOG_LEVEL,
          redact: ["req.headers.authorization", "req.headers.cookie"],
        }
      : false,
    bodyLimit: 4 * 1024 * 1024,
    trustProxy: (_address, hop) => hop < configuration.trustedProxyHops,
  });
  const secret = configuration.jwtSecret;
  const origins = [
    ...permittedOrigins,
    ...(process.env.CORS_ORIGINS || "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  ];
  await app.register(cors, {
    origin: origins,
    methods: ["GET", "HEAD", "POST", "DELETE"],
  });
  await app.register(rateLimit, { max: 500, timeWindow: "1 minute" });
  app.setErrorHandler((error: any, _request, reply) =>
    reply.code(error.statusCode || 500).send({
      error: error.statusCode
        ? error.message
        : "The server could not complete this operation.",
    }),
  );
  app.addHook("preSerialization", async (request: any, _reply, payload: any) =>
    request.actor?.role === "cashier" ? withoutCost(payload) : payload,
  );
  app.get("/api/v1/health", async () => {
    await db.query("SELECT 1");
    return {
      status: "ok",
      database: process.env.DATABASE_URL ? "postgresql" : "pglite-development",
      version: "1.1.0",
    };
  });
  app.post(
    "/api/v1/auth/login",
    { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
    async (request: any) => {
      const body = request.body || {};
      const org = text(
        body.organizationId || (configuration.production ? "" : "demo"),
        "organization code",
        true,
        64,
      );
      const email = text(body.email, "email", true, 254).toLowerCase();
      const user = (await records(db, org, "user")).find(
        (user) => user.email.toLowerCase() === email,
      );
      if (
        !user ||
        !user.active ||
        typeof body.password !== "string" ||
        !validPassword(body.password, user.passwordHash)
      )
        fail("Invalid email or password.", 401);
      const branchId = body.branchId || user.branchIds[0];
      if (!user.branchIds.includes(branchId))
        fail("This account cannot access that branch.", 403);
      const settings = (await getRecord(db, org, "settings", "settings"))!;
      const expiresAt = new Date(
        Date.now() + settings.sessionHours * 3600000,
      ).toISOString();
      const token = jwt.sign(
        {
          sub: user.id,
          organizationId: org,
          branchId,
          authVersion: user.authVersion || 0,
        },
        secret,
        { expiresIn: settings.sessionHours * 3600, algorithm: "HS256" },
      );
      const { passwordHash, ...publicUser } = user;
      return {
        token,
        user: publicUser,
        branchId,
        organizationId: org,
        expiresAt,
      };
    },
  );
  app.addHook("preHandler", async (request: any) => {
    if (
      request.url.split("?")[0].endsWith("/health") ||
      request.url.split("?")[0].endsWith("/auth/login") ||
      request.method === "OPTIONS"
    )
      return;
    let claims: any;
    try {
      claims = jwt.verify(
        String(request.headers.authorization || "").replace(/^Bearer /, ""),
        secret,
        { algorithms: ["HS256"] },
      );
    } catch {
      fail("Sign in again. Your session has expired.", 401);
    }
    const user = await getRecord(db, claims.organizationId, "user", claims.sub);
    if (!user?.active || !user.branchIds.includes(claims.branchId))
      fail("Account access has been revoked.", 403);
    if (
      (claims.authVersion || 0) !== (user.authVersion || 0) ||
      typeof claims.exp !== "number"
    )
      fail("Your session was revoked. Sign in again.", 401);
    const policy = await getRecord(
      db,
      claims.organizationId,
      "settings",
      "settings",
    );
    if (
      !policy ||
      typeof claims.iat !== "number" ||
      Date.now() >= (claims.iat + policy.sessionHours * 3600) * 1000
    )
      fail(
        "Sign in again. Your session has expired under the current policy.",
        401,
      );
    request.actor = {
      id: user.id,
      name: user.name,
      role: user.role,
      organizationId: claims.organizationId,
      branchId: claims.branchId,
    } satisfies Actor;
  });
  app.get("/api/v1/bootstrap", async (request: any) => {
    const actor: Actor = request.actor;
    const data: any = {
      lastSync: now(),
      organization: await getRecord(
        db,
        actor.organizationId,
        "organization",
        actor.organizationId,
      ),
      branch: await getRecord(
        db,
        actor.organizationId,
        "branch",
        actor.branchId,
      ),
      user: actor,
    };
    const user = (await getRecord(db, actor.organizationId, "user", actor.id))!;
    data.users =
      actor.role === "owner"
        ? (await records(db, actor.organizationId, "user")).map(
            ({ passwordHash, ...entry }) => entry,
          )
        : [];
    data.branches = (await records(db, actor.organizationId, "branch")).filter(
      (branch) => user.branchIds.includes(branch.id),
    );
    for (const [plural, kind, scope] of [
      ["products", "product", ""],
      ["vehicles", "vehicle", ""],
      ["customers", "customer", ""],
      ["suppliers", "supplier", ""],
      ["locations", "location", "branch"],
      ["purchaseOrders", "purchaseOrder", "branch"],
      ["invoices", "invoice", "branch"],
      ["returns", "return", "branch"],
      ["shifts", "shift", "branch"],
      ["holds", "hold", "branch"],
      ["transfers", "transfer", ""],
      ["warrantyClaims", "warranty", "branch"],
      ["coreReturns", "coreReturn", "branch"],
      ["conflicts", "conflict", "branch"],
      ["devices", "device", "branch"],
      ["audit", "audit", "branch"],
    ])
      data[plural] = await records(
        db,
        actor.organizationId,
        kind,
        scope === "branch" ? actor.branchId : undefined,
      );
    data.transfers = data.transfers.filter(
      (transfer: any) =>
        transfer.branchId === actor.branchId ||
        transfer.destinationBranchId === actor.branchId,
    );
    if (actor.role === "cashier") {
      data.audit = [];
      data.conflicts = [];
      data.invoices = data.invoices.filter(
        (invoice: any) => invoice.cashierId === actor.id,
      );
    }
    data.stock = await inventory(db, actor);
    data.settings = await getRecord(
      db,
      actor.organizationId,
      "settings",
      "settings",
    );
    data.catalogRevision = createHash("sha256")
      .update(
        JSON.stringify({
          products: data.products,
          customers: data.customers,
          settings: {
            ...invoiceProfile(data.settings, data.branch),
            roundingIncrement: data.settings.roundingIncrement,
            invoicePrefix: data.settings.invoicePrefix,
          },
          branchId: actor.branchId,
        }),
      )
      .digest("hex");
    if (
      !(
        await db.query(
          "SELECT 1 FROM records WHERE organization_id=$1 AND kind='catalogSnapshot' AND id=$2",
          [actor.organizationId, data.catalogRevision],
        )
      ).rows.length
    )
      await putRecord(db, actor.organizationId, "catalogSnapshot", {
        id: data.catalogRevision,
        products: data.products,
        customers: data.customers,
        settings: { ...data.settings },
        branch: data.branch,
        branchId: actor.branchId,
        issuedAt: now(),
      });
    if (actor.role === "cashier") {
      data.products = data.products.map(({ cost, ...product }: any) => product);
      data.invoices = data.invoices.map(({ cost, ...invoice }: any) => ({
        ...invoice,
        lines: invoice.lines.map(({ cost, ...line }: any) => line),
      }));
      data.purchaseOrders = [];
      data.returns = data.returns.filter(
        (entry: any) => entry.userId === actor.id,
      );
    }
    return data;
  });
  const post = (
    path: string,
    handler: (
      db: Database,
      actor: Actor,
      body: any,
      params: any,
    ) => Promise<any>,
  ) =>
    app.post("/api/v1/" + path, async (request: any) =>
      db.transaction((tx) => {
        const body = request.body || {};
        const handlesIdempotency =
          path === "invoices" ||
          path === "core-returns" ||
          path === "invoices/:id/returns" ||
          path === "purchase-orders/:id/receive";
        const operation = () =>
          handler(tx, request.actor, body, request.params);
        if (body.transactionId && !handlesIdempotency && path !== "approvals")
          return idempotent(
            tx,
            request.actor,
            body.transactionId,
            { path, params: request.params, body },
            operation,
          );
        return operation();
      }),
    );
  post("users", async (tx, actor, body) => {
    allow(actor, ["owner"]);
    const users = await records(tx, actor.organizationId, "user");
    if (!roles.includes(body.role)) fail("Choose a valid role.");
    const email = emailAddress(body.email);
    if (
      users.some(
        (user) =>
          user.email.toLowerCase() === email.toLowerCase() &&
          user.id !== body.id,
      )
    )
      fail("Email is already registered.", 409);
    if (!Array.isArray(body.branchIds) || !body.branchIds.length)
      fail("Assign at least one branch.");
    for (const branchId of body.branchIds)
      if (!(await getRecord(tx, actor.organizationId, "branch", branchId)))
        fail("Unknown branch.");
    const existing = body.id
      ? await getRecord(tx, actor.organizationId, "user", body.id)
      : undefined;
    if (
      body.id === actor.id &&
      (body.active === false || body.role !== "owner")
    )
      fail("The active owner cannot remove their own access.");
    if (!existing || body.password) {
      if (
        typeof body.password !== "string" ||
        body.password.length < 12 ||
        body.password.length > 256
      )
        fail("Password requires between 12 and 256 characters.");
    }
    const user = {
      id: body.id || id("user"),
      organizationId: actor.organizationId,
      name: text(body.name, "name"),
      email,
      passwordHash: body.password
        ? hashPassword(body.password)
        : existing?.passwordHash,
      role: body.role,
      branchIds: body.branchIds,
      active: body.active !== false,
      authVersion: (existing?.authVersion || 0) + 1,
    };
    await putRecord(tx, actor.organizationId, "user", user);
    await audit(tx, actor, "user-update", user.id, "User access management", {
      role: user.role,
      branches: user.branchIds,
    });
    const { passwordHash, ...result } = user;
    return result;
  });
  post("branches", async (tx, actor, body) => {
    allow(actor, ["owner"]);
    const branchId = text(body.id, "branch code", true, 64);
    if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(branchId))
      fail(
        "Branch code must use lowercase letters, numbers, hyphens, or underscores.",
      );
    const branch = {
      id: branchId,
      name: text(body.name, "branch name"),
      address: multiline(body.address || "", "branch address"),
      stateCode: text(body.stateCode || "", "state code", false, 50),
    };
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    gstProfile(invoiceProfile(settings, branch));
    await putRecord(tx, actor.organizationId, "branch", branch);
    const owner = (await getRecord(
      tx,
      actor.organizationId,
      "user",
      actor.id,
    ))!;
    if (!owner.branchIds.includes(branchId)) {
      owner.branchIds.push(branchId);
      await putRecord(tx, actor.organizationId, "user", owner);
    }
    await audit(tx, actor, "branch", branchId, "Branch configuration updated");
    return branch;
  });
  post("settings", async (tx, actor, body) => {
    allow(actor, ["owner"]);
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    if (body.currency !== undefined) {
      const currency = currencyCode(body.currency);
      if (currency !== settings.currency) {
        const monetary = await tx.query(
          "SELECT 1 FROM records WHERE organization_id=$1 AND kind IN ('invoice','purchaseOrder','purchaseReceipt','return','coreReturn','shift') LIMIT 1",
          [actor.organizationId],
        );
        if (monetary.rows.length)
          fail(
            "Currency cannot change after monetary records exist. Create a separate organization for another accounting currency.",
            409,
          );
      }
      settings.currency = currency;
    }
    if (body.invoicePrefix !== undefined)
      settings.invoicePrefix = text(
        body.invoicePrefix,
        "invoice prefix",
        true,
        24,
      );
    if (body.creditNotePrefix !== undefined)
      settings.creditNotePrefix = text(
        body.creditNotePrefix,
        "credit-note prefix",
        true,
        24,
      );
    if (body.business !== undefined)
      settings.business = {
        ...settings.business,
        ...businessProfile(body.business),
      };
    if (body.taxScheme !== undefined) {
      if (!["general", "india-gst"].includes(body.taxScheme))
        fail("Choose a supported tax scheme.");
      settings.taxScheme = body.taxScheme;
    }
    if (body.localTaxName !== undefined) {
      if (!["SGST", "UTGST"].includes(body.localTaxName))
        fail("Choose SGST or UTGST.");
      settings.localTaxName = body.localTaxName;
    }
    if (body.taxMode !== undefined) {
      if (!["inclusive", "exclusive"].includes(body.taxMode))
        fail("Choose inclusive or exclusive tax mode.");
      settings.taxMode = body.taxMode;
    }
    if (body.taxDisplayName !== undefined)
      settings.taxDisplayName = text(
        body.taxDisplayName,
        "tax display name",
        true,
        60,
      );
    if (body.receiptFooter !== undefined)
      settings.receiptFooter = multiline(body.receiptFooter, "receipt footer");
    if (body.tenderTypes !== undefined) {
      if (
        !Array.isArray(body.tenderTypes) ||
        !body.tenderTypes.length ||
        body.tenderTypes.some(
          (entry: any) => !["Cash", "Card", "UPI"].includes(entry),
        )
      )
        fail("Choose at least one supported tender.");
      settings.tenderTypes = [...new Set(body.tenderTypes)];
    }
    if (body.nextInvoice !== undefined) {
      const number = integer(
        body.nextInvoice,
        "Next invoice number",
        settings.nextInvoice,
        Number.MAX_SAFE_INTEGER - 100001,
      );
      const issued = await records(tx, actor.organizationId, "invoice");
      if (issued.some((invoice) => invoice.invoiceNumber === number))
        fail("That invoice number has already been issued.", 409);
      settings.nextInvoice = number;
    }
    const branch = (await getRecord(
      tx,
      actor.organizationId,
      "branch",
      actor.branchId,
    ))!;
    if (body.branchName !== undefined)
      branch.name = text(body.branchName, "branch name");
    if (body.branchAddress !== undefined)
      branch.address = multiline(body.branchAddress, "branch address");
    if (body.branchStateCode !== undefined)
      branch.stateCode = text(
        body.branchStateCode,
        "branch state code",
        false,
        50,
      );
    gstProfile(invoiceProfile(settings, branch));
    documentNumber(
      `${settings.invoicePrefix}-${branch.id.toUpperCase()}-${settings.nextInvoice}`,
      settings.taxScheme,
    );
    documentNumber(
      `${settings.creditNotePrefix || "CR"}-${branch.id.toUpperCase()}-${settings.nextCreditNote || 1}`,
      settings.taxScheme,
    );
    await putRecord(tx, actor.organizationId, "branch", branch);
    for (const [key, min, max] of [
      ["offlineHours", 0, 168],
      ["sessionHours", 1, 168],
      ["cashierDiscountLimit", 0, 1000000],
      ["roundingIncrement", 1, 10000],
    ] as const)
      if (body[key] !== undefined)
        settings[key] = integer(body[key], key, min, max);
    if (body.offlineTenders) {
      if (
        !Array.isArray(body.offlineTenders) ||
        body.offlineTenders.some((type: any) => !["Cash"].includes(type))
      )
        fail("Only cash is supported without provider confirmation.");
      settings.offlineTenders = body.offlineTenders;
    }
    if (body.features !== undefined) {
      if (!body.features || typeof body.features !== "object" || Array.isArray(body.features))
        fail("Choose which modules are switched on.");
      const features: Record<string, boolean> = { ...(settings.features || {}) };
      for (const [key, value] of Object.entries(body.features)) {
        if (!["transfers", "fitment", "offline", "warranty"].includes(key))
          fail("Unknown module.");
        if (typeof value !== "boolean") fail("Module switches must be on or off.");
        features[key] = value;
      }
      settings.features = features;
    }
    if (body.taxRates !== undefined) {
      if (
        !Array.isArray(body.taxRates) ||
        !body.taxRates.length ||
        body.taxRates.length > 100
      )
        fail("Provide between one and 100 tax rates.");
      settings.taxRates = body.taxRates.map((rate: any) =>
        integer(rate, "Tax rate", 0, 10000),
      );
    }
    await audit(
      tx,
      actor,
      "settings",
      "settings",
      "Configuration change",
      body,
    );
    return putRecord(tx, actor.organizationId, "settings", settings);
  });
  post("products", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const existing = body.id
      ? await scoped(tx, actor, "product", body.id)
      : undefined;
    const value = { ...existing, ...body };
    const product: any = { id: existing?.id || id("part") };
    for (const key of [
      "name",
      "sku",
      "brand",
      "partNumber",
      "category",
      "unit",
    ])
      product[key] = text(value[key] ?? "", key, key !== "partNumber");
    product.description = text(
      value.description || "",
      "description",
      false,
      2000,
    );
    product.hsnSac = text(value.hsnSac || "", "HSN or SAC", false, 30);
    for (const key of [
      "cost",
      "retailPrice",
      "wholesalePrice",
      "coreCharge",
      "reorderLevel",
    ])
      product[key] = integer(value[key] ?? 0, key);
    product.taxRate = integer(value.taxRate ?? 1800, "Tax rate", 0, 10000);
    product.packSize = integer(value.packSize ?? 1, "Pack size", 1, 9999);
    for (const key of [
      "oemReferences",
      "barcodes",
      "supplierReferences",
      "alternatives",
      "supersedes",
      "interchanges",
    ]) {
      if (value[key] !== undefined && !Array.isArray(value[key]))
        fail(`${key} must be an array.`);
      product[key] = (value[key] || []).map((entry: any) =>
        text(entry, key, true, 100),
      );
    }
    Object.assign(product, {
      taxCategory: value.taxCategory || "Standard",
      supplierId: value.supplierId || null,
      serialTracked: !!value.serialTracked,
      universal: !!value.universal,
      type: value.type === "service" ? "service" : "part",
      icon: value.icon || "",
      fitments: value.fitments || [],
    });
    for (const rule of product.fitments) validateFitment(rule);
    const products = await records(tx, actor.organizationId, "product");
    if (
      existing &&
      (existing.serialTracked !== product.serialTracked ||
        existing.type !== product.type)
    ) {
      const stocked = await tx.query(
        "SELECT 1 FROM stock WHERE organization_id=$1 AND product_id=$2 AND quantity<>0 LIMIT 1",
        [actor.organizationId, product.id],
      );
      if (stocked.rows.length)
        fail(
          "Clear existing stock through audited operations before changing serial tracking or item type.",
          409,
        );
    }
    const existingBarcodes = new Set((existing?.barcodes || []).map(barcodeKey));
    const addedBarcodes = product.barcodes.filter((code: string) => !existingBarcodes.has(barcodeKey(code)));
    for (const other of products) {
      if (other.id === product.id) continue;
      const otherBarcodes: string[] = other.barcodes || [];
      const sku = normalize(product.sku);
      if (
        sku === normalize(other.sku) ||
        (sku !== normalize(existing?.sku) && otherBarcodes.some((code) => normalize(code) === sku)) ||
        addedBarcodes.some((code: string) =>
          otherBarcodes.some((barcode) => barcodeKey(barcode) === barcodeKey(code)) ||
          normalize(code) === normalize(other.sku),
        )
      ) fail(`SKU or barcode conflicts with ${other.name}.`, 409);
    }
    if (
      existing &&
      (await records(tx, actor.organizationId, "hold")).some((hold) =>
        hold.cart.lines.some((line: any) => line.productId === product.id),
      )
    )
      fail("Complete or release parked sales before editing this part.", 409);
    await audit(tx, actor, "product", product.id, "Catalog update");
    return putRecord(tx, actor.organizationId, "product", product);
  });
  for (const kind of ["customer", "supplier"] as const)
    post(kind + "s", async (tx, actor, body) => {
      allow(
        actor,
        kind === "customer"
          ? ["owner", "manager", "cashier"]
          : ["owner", "manager", "inventory"],
      );
      const entity = {
        id: body.id || id(kind),
        name: text(body.name, "name"),
        phone: String(body.phone || ""),
        email: emailAddress(body.email || "", false),
        address: multiline(body.address || "", "address"),
        taxRegistrationId: text(
          body.taxRegistrationId || "",
          "tax registration ID",
          false,
          100,
        ),
        stateCode: text(body.stateCode || "", "state code", false, 50),
        vehicle: body.vehicle || null,
      };
      if (body.id) await scoped(tx, actor, kind, body.id);
      return putRecord(tx, actor.organizationId, kind, entity);
    });
  post("locations", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const existing = body.id
      ? await scoped(tx, actor, "location", body.id)
      : undefined;
    const value = { ...existing, ...body };
    const location: any = {
      id: existing?.id || id("bin"),
      branchId: actor.branchId,
    };
    for (const key of ["area", "rack", "shelf", "bin"])
      location[key] = text(value[key], key);
    location.kind = value.kind || "sellable";
    if (!["sellable", "damaged", "warranty"].includes(location.kind))
      fail("Unknown bin kind.");
    if (existing && location.kind !== existing.kind)
      fail("Create a new bin to change its stock condition.");
    await audit(
      tx,
      actor,
      "location",
      location.id,
      "Location label update",
      location,
    );
    return putRecord(
      tx,
      actor.organizationId,
      "location",
      location,
      actor.branchId,
    );
  });
  post("fitments", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const product = await scoped(tx, actor, "product", body.productId);
    validateFitment(body);
    const rule = { ...body, id: body.id || id("fitment") };
    product.fitments = [
      ...product.fitments.filter((entry: any) => entry.id !== rule.id),
      rule,
    ];
    await putRecord(tx, actor.organizationId, "product", product);
    await audit(tx, actor, "fitment", product.id, "Fitment update", {
      source: rule.source,
    });
    return rule;
  });
  post("fitments/check", async (tx, actor, body) =>
    fitment(await scoped(tx, actor, "product", body.productId), body.vehicle),
  );
  const csvPreview = async (tx: Database, actor: Actor, body: any) => {
    let rows: any[];
    try {
      rows = parse(body.csv, {
        columns: true,
        skip_empty_lines: true,
        trim: true,
      });
    } catch {
      fail("CSV could not be parsed.");
    }
    if (rows.length > 10000) fail("Import at most 10,000 rows per batch.");
    const results: any[] = [];
    const duplicates = new Set<string>();
    for (let index = 0; index < rows.length; index++) {
      const row = {
        ...rows[index],
        yearFrom: Number(rows[index].yearFrom),
        yearTo: Number(rows[index].yearTo),
        exclusions: [],
      };
      const errors: string[] = [];
      try {
        validateFitment(row);
        await scoped(tx, actor, "product", row.productId);
      } catch (error: any) {
        errors.push(error.message);
      }
      const key = fitmentKey(row);
      if (duplicates.has(key)) errors.push("Duplicate row in this file.");
      duplicates.add(key);
      const product = await getRecord(
        tx,
        actor.organizationId,
        "product",
        row.productId,
      );
      results.push({
        row: index + 2,
        data: row,
        errors,
        duplicate: !!product?.fitments.some(
          (rule: any) => fitmentKey(rule) === key,
        ),
      });
    }
    return {
      rows: results,
      valid: results.every((row) => !row.errors.length),
      errors: results.flatMap((row) =>
        row.errors.map((message: string) => ({ row: row.row, message })),
      ),
    };
  };
  post("fitments/import/preview", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    return csvPreview(tx, actor, body);
  });
  post("fitments/import", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const preview = await csvPreview(tx, actor, body);
    if (!preview.valid) fail("Resolve row errors before importing.");
    if (!["skip", "replace"].includes(body.duplicateHandling))
      fail("Choose skip or replace duplicate handling.");
    let imported = 0;
    for (const row of preview.rows) {
      if (row.duplicate && body.duplicateHandling === "skip") continue;
      const product = await scoped(tx, actor, "product", row.data.productId);
      product.fitments = [
        ...product.fitments.filter(
          (rule: any) => fitmentKey(rule) !== fitmentKey(row.data),
        ),
        { ...row.data, id: id("fitment") },
      ];
      await putRecord(tx, actor.organizationId, "product", product);
      imported++;
    }
    await audit(tx, actor, "fitment-import", "catalog", "CSV import", {
      imported,
    });
    return { imported, skipped: preview.rows.length - imported };
  });
  post("inventory/move", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const quantity = integer(body.quantity, "Quantity", 1);
    text(body.reason, "reason");
    const from = await scoped(tx, actor, "location", body.fromBinId),
      to = await scoped(tx, actor, "location", body.toBinId);
    if (from.id === to.id) fail("Choose a different destination bin.");
    if (from.kind !== to.kind)
      fail("Use an audited return or adjustment to change stock condition.");
    const stock = (await inventory(tx, actor)).find(
      (item) =>
        item.productId === body.productId && item.binId === body.fromBinId,
    );
    if (!stock || stock.available < quantity)
      fail("Movement would consume reserved or unavailable stock.", 409);
    const reference = id("move");
    await adjust(
      tx,
      actor,
      body.productId,
      body.fromBinId,
      -quantity,
      body.reason,
      reference,
    );
    await adjust(
      tx,
      actor,
      body.productId,
      body.toBinId,
      quantity,
      body.reason,
      reference,
    );
    const product = await scoped(tx, actor, "product", body.productId);
    if (product.serialTracked) {
      if (
        !Array.isArray(body.serials) ||
        body.serials.length !== quantity ||
        new Set(body.serials).size !== quantity
      )
        fail("Select one serial for each moved unit.");
      for (const serial of body.serials) {
        const item = await scoped(
          tx,
          actor,
          "serial",
          product.id + ":" + serial,
        );
        if (item.status !== "available" || item.binId !== body.fromBinId)
          fail("Serial is unavailable in the source bin.");
        await putRecord(
          tx,
          actor.organizationId,
          "serial",
          { ...item, binId: body.toBinId },
          actor.branchId,
        );
      }
    }
    await audit(tx, actor, "stock-move", reference, body.reason, body);
    return { id: reference };
  });
  for (const operation of ["adjust", "count"])
    post(`inventory/${operation}`, async (tx, actor, body) => {
      allow(actor, ["owner", "manager", "inventory"]);
      text(body.reason, "reason");
      await approved(
        tx,
        actor,
        "adjustment",
        body.approvalId,
        body.transactionId || body.productId + body.binId,
      );
      const stock = (await inventory(tx, actor)).find(
        (item) =>
          item.productId === body.productId && item.binId === body.binId,
      );
      const quantity =
        operation === "count"
          ? integer(body.counted, "Counted quantity") - (stock?.quantity || 0)
          : integer(body.quantity, "Adjustment", -1000000, 1000000);
      if ((stock?.available || 0) + quantity < 0)
        fail("Adjustment would consume reserved stock.", 409);
      const reference = id(operation);
      await adjust(
        tx,
        actor,
        body.productId,
        body.binId,
        quantity,
        body.reason,
        reference,
      );
      const product = await scoped(tx, actor, "product", body.productId);
      if (product.serialTracked && quantity !== 0) {
        if (
          !Array.isArray(body.serials) ||
          body.serials.length !== Math.abs(quantity) ||
          new Set(body.serials).size !== Math.abs(quantity)
        )
          fail("Provide one serial for every adjusted unit.");
        for (const serial of body.serials) {
          text(serial, "serial");
          const serialId = product.id + ":" + serial;
          const existing = await getRecord(
            tx,
            actor.organizationId,
            "serial",
            serialId,
          );
          if (quantity > 0) {
            if (existing) fail("Serial already exists.");
            await putRecord(
              tx,
              actor.organizationId,
              "serial",
              {
                id: serialId,
                branchId: actor.branchId,
                productId: product.id,
                serial,
                binId: body.binId,
                status: "available",
              },
              actor.branchId,
            );
          } else {
            if (
              !existing ||
              existing.branchId !== actor.branchId ||
              existing.binId !== body.binId ||
              existing.status !== "available"
            )
              fail("Serial is unavailable in the counted bin.");
            await putRecord(
              tx,
              actor.organizationId,
              "serial",
              { ...existing, status: "adjusted-out" },
              actor.branchId,
            );
          }
        }
      }
      await audit(tx, actor, "stock-" + operation, reference, body.reason, {
        ...body,
        quantity,
      });
      return { id: reference, quantity };
    });
  post("purchase-orders", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    await scoped(tx, actor, "supplier", body.supplierId);
    if (!Array.isArray(body.lines) || !body.lines.length)
      fail("Add purchase lines.");
    const lines = [];
    const used = new Set<string>();
    for (const line of body.lines) {
      await scoped(tx, actor, "product", line.productId);
      if (used.has(line.productId)) fail("Combine duplicate purchase lines.");
      used.add(line.productId);
      lines.push({
        productId: line.productId,
        quantity: integer(line.quantity, "Quantity", 1),
        cost: integer(line.cost, "Cost"),
        received: 0,
      });
    }
    const order = {
      id: id("po"),
      branchId: actor.branchId,
      supplierId: body.supplierId,
      lines,
      status: "open",
      createdAt: now(),
      userId: actor.id,
    };
    await audit(
      tx,
      actor,
      "purchase-order",
      order.id,
      "Purchase order created",
    );
    return putRecord(
      tx,
      actor.organizationId,
      "purchaseOrder",
      order,
      actor.branchId,
    );
  });
  post("purchase-orders/:id/receive", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    return idempotent(
      tx,
      actor,
      body.transactionId,
      { purchaseOrderId: params.id, body },
      async () => {
        const order = await scoped(tx, actor, "purchaseOrder", params.id);
        if (!Array.isArray(body.lines) || !body.lines.length)
          fail("Select receipt lines.");
        const landedCost = integer(body.landedCost || 0, "Landed cost");
        const receiptId = id("receipt");
        const lines = [];
        let allocated = 0,
          cumulative = 0;
        const totalUnits = body.lines.reduce(
          (sum: number, line: any) =>
            sum + integer(line.quantity, "Quantity", 1),
          0,
        );
        for (const input of body.lines) {
          const line = order.lines.find(
            (line: any) => line.productId === input.productId,
          );
          if (!line) fail("Part is not on this purchase order.");
          const quantity = integer(
            input.quantity,
            "Received quantity",
            1,
            line.quantity - line.received,
          );
          const product = await scoped(tx, actor, "product", line.productId);
          const bin = await scoped(tx, actor, "location", input.binId);
          if (bin.kind !== "sellable")
            fail("Purchases must be put away into a sellable bin.");
          cumulative += quantity;
          const next = roundRatio(landedCost, cumulative, totalUnits);
          const extra = next - allocated;
          allocated = next;
          product.cost = line.cost + roundRatio(extra, 1, quantity);
          await putRecord(tx, actor.organizationId, "product", product);
          if (product.serialTracked) {
            if (
              !Array.isArray(input.serials) ||
              input.serials.length !== quantity ||
              new Set(input.serials).size !== quantity
            )
              fail("Receive one unique serial per unit.");
            for (const serial of input.serials) {
              text(serial, "serial");
              const serialId = product.id + ":" + serial;
              if (await getRecord(tx, actor.organizationId, "serial", serialId))
                fail("Serial already exists.");
              await putRecord(
                tx,
                actor.organizationId,
                "serial",
                {
                  id: serialId,
                  branchId: actor.branchId,
                  productId: product.id,
                  serial,
                  binId: bin.id,
                  status: "available",
                },
                actor.branchId,
              );
            }
          }
          await adjust(
            tx,
            actor,
            product.id,
            bin.id,
            quantity,
            "Goods receipt",
            receiptId,
          );
          line.received += quantity;
          lines.push({
            productId: product.id,
            quantity,
            binId: bin.id,
            cost: line.cost,
            landedCost: extra,
          });
        }
        order.status = order.lines.every(
          (line: any) => line.received === line.quantity,
        )
          ? "received"
          : "partial";
        await putRecord(
          tx,
          actor.organizationId,
          "purchaseOrder",
          order,
          actor.branchId,
        );
        const receipt = {
          id: receiptId,
          branchId: actor.branchId,
          purchaseOrderId: order.id,
          supplierId: order.supplierId,
          lines,
          landedCost,
          createdAt: now(),
          userId: actor.id,
        };
        await audit(tx, actor, "goods-receipt", receiptId, "Goods received");
        return putRecord(
          tx,
          actor.organizationId,
          "purchaseReceipt",
          receipt,
          actor.branchId,
        );
      },
    );
  });
  post("shifts/open", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "cashier"]);
    if (
      (await records(tx, actor.organizationId, "shift", actor.branchId)).some(
        (shift) => shift.userId === actor.id && !shift.closedAt,
      )
    )
      fail("You already have an open shift.", 409);
    const shift = {
      id: id("shift"),
      branchId: actor.branchId,
      userId: actor.id,
      openedAt: now(),
      openingCash: integer(body.openingCash || 0, "Opening cash"),
    };
    return putRecord(tx, actor.organizationId, "shift", shift, actor.branchId);
  });
  post("shifts/:id/close", async (tx, actor, body, params) => {
    const shift = await scoped(tx, actor, "shift", params.id);
    if (shift.userId !== actor.id) allow(actor, ["owner", "manager"]);
    if (shift.closedAt) fail("Shift already closed.", 409);
    const sales = (
      await records(tx, actor.organizationId, "invoice", actor.branchId)
    ).filter((sale) => sale.shiftId === shift.id);
    const refunds = (
      await records(tx, actor.organizationId, "return", actor.branchId)
    ).filter((item) => item.shiftId === shift.id && item.refundType === "Cash");
    const coreRefunds = (
      await records(tx, actor.organizationId, "coreReturn", actor.branchId)
    ).filter((item) => item.shiftId === shift.id && item.refundType === "Cash");
    shift.expectedCash =
      shift.openingCash +
      sales.reduce(
        (sum, sale) =>
          sum +
          sale.tenders
            .filter((tender: any) => tender.type === "Cash")
            .reduce((n: number, tender: any) => n + tender.amount, 0) -
          sale.change,
        0,
      ) -
      refunds.reduce((sum, item) => sum + item.total, 0) -
      coreRefunds.reduce((sum, item) => sum + item.total, 0);
    shift.countedCash = integer(body.countedCash, "Counted cash");
    shift.variance = shift.countedCash - shift.expectedCash;
    shift.closedAt = now();
    shift.reason = text(body.reason || "Shift close", "reason");
    await audit(tx, actor, "shift-close", shift.id, shift.reason, {
      variance: shift.variance,
    });
    return putRecord(tx, actor.organizationId, "shift", shift, actor.branchId);
  });
  post("approvals", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    if (!["fitment", "discount", "return", "adjustment"].includes(body.action))
      fail("Unknown approval action.");
    const approval = {
      id: id("approval"),
      branchId: actor.branchId,
      action: body.action,
      transactionId: text(body.transactionId, "transaction ID"),
      reason: text(body.reason, "reason"),
      approvedBy: actor.id,
      used: false,
      expiresAt: new Date(Date.now() + 900000).toISOString(),
    };
    await audit(tx, actor, "approval", approval.id, approval.reason, {
      action: approval.action,
    });
    return putRecord(
      tx,
      actor.organizationId,
      "approval",
      approval,
      actor.branchId,
    );
  });
  post("invoices", async (tx, actor, body) =>
    idempotent(tx, actor, body.transactionId, body, () =>
      finalizeSale(tx, actor, body),
    ),
  );
  post("invoices/:id/returns", async (tx, actor, body, params) =>
    idempotent(
      tx,
      actor,
      body.transactionId,
      { invoiceId: params.id, body },
      () => returnInvoice(tx, actor, params.id, body),
    ),
  );
  post("invoices/:id/void", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const invoice = await scoped(tx, actor, "invoice", params.id);
    if (
      (await records(tx, actor.organizationId, "return", actor.branchId)).some(
        (item) => item.invoiceId === invoice.id,
      )
    )
      fail("Void requires an invoice with no prior returns.");
    if (
      (
        await records(tx, actor.organizationId, "coreReturn", actor.branchId)
      ).some((item) => item.invoiceId === invoice.id)
    )
      fail("Use line credit notes after a prior core refund.");
    const credit = await returnInvoice(
      tx,
      actor,
      invoice.id,
      {
        ...body,
        transactionId: body.transactionId || id("void"),
        condition: "sellable",
        lines: invoice.lines.map((line: any) => ({
          lineId: line.id,
          quantity: line.qty,
          binId: line.binId,
          serials: line.serials,
        })),
      },
      true,
    );
    let coreRefundTotal = 0;
    for (const line of invoice.lines.filter(
      (line: any) => line.coreCharge > 0,
    )) {
      const core = {
        id: id("core"),
        branchId: actor.branchId,
        invoiceId: invoice.id,
        productId: line.productId,
        quantity: line.qty,
        total: line.qty * line.coreCharge,
        reason: body.reason,
        refundType: body.refundType || "Cash",
        createdAt: now(),
        userId: actor.id,
        shiftId: credit.shiftId,
        voidId: credit.id,
      };
      await putRecord(
        tx,
        actor.organizationId,
        "coreReturn",
        core,
        actor.branchId,
      );
      await audit(tx, actor, "core-void", core.id, body.reason, {
        invoiceId: invoice.id,
      });
      coreRefundTotal += core.total;
    }
    return {
      ...credit,
      coreRefundTotal,
      totalRefund: credit.total + coreRefundTotal,
    };
  });
  post("holds", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "cashier"]);
    const cart = body.cart;
    if (
      !Array.isArray(cart?.lines) ||
      !cart.lines.length ||
      cart.lines.length > 200
    )
      fail("Park between one and 200 cart lines.");
    const previous = body.id
      ? await scoped(tx, actor, "hold", body.id)
      : undefined;
    const stock = await inventory(tx, actor);
    const quantities = new Map<string, number>();
    for (const line of cart.lines) {
      const quantity = integer(line.qty, "Quantity", 1, 9999);
      line.qty = quantity;
      const product = await scoped(tx, actor, "product", line.productId);
      if (product.type === "service") continue;
      await scoped(tx, actor, "location", line.binId);
      const key = line.productId + "|" + line.binId;
      quantities.set(key, (quantities.get(key) || 0) + quantity);
      const own = (previous?.cart.lines || [])
        .filter(
          (entry: any) =>
            entry.productId === line.productId && entry.binId === line.binId,
        )
        .reduce((sum: number, entry: any) => sum + entry.qty, 0);
      if (
        (stock.find(
          (item) =>
            item.productId === line.productId && item.binId === line.binId,
        )?.available || 0) +
          own <
        quantities.get(key)!
      )
        fail("Insufficient stock to park this bill.", 409);
    }
    const hold = {
      id: previous?.id || id("hold"),
      branchId: actor.branchId,
      userId: actor.id,
      cart,
      createdAt: previous?.createdAt || now(),
    };
    return putRecord(tx, actor.organizationId, "hold", hold, actor.branchId);
  });
  app.delete("/api/v1/holds/:id", async (request: any) =>
    db.transaction(async (tx) => {
      const actor = request.actor;
      allow(actor, ["owner", "manager", "cashier"]);
      await scoped(tx, actor, "hold", request.params.id);
      await tx.query(
        "DELETE FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3",
        [actor.organizationId, "hold", request.params.id],
      );
      return { deleted: true };
    }),
  );
  post("devices/enroll", async (tx, actor, body) => {
    allow(actor, ["owner", "manager"]);
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    const rangeSize = integer(
      body.rangeSize || 1000,
      "Invoice range size",
      10,
      100000,
    );
    const hours = integer(
      body.offlineHours ?? settings.offlineHours,
      "Offline hours",
      0,
      settings.offlineHours,
    );
    const tenders = body.tenders || settings.offlineTenders;
    if (
      !Array.isArray(tenders) ||
      tenders.some((tender: any) => !settings.offlineTenders.includes(tender))
    )
      fail("Offline tenders exceed organization policy.");
    const device = {
      id: id("device"),
      branchId: actor.branchId,
      name: text(body.name, "device name"),
      offlineAllowed: body.offlineAllowed === true,
      offlineUntil: new Date(Date.now() + hours * 3600000).toISOString(),
      enrolledAt: now(),
      enrolledBy: actor.id,
      tenders,
      rangeStart: settings.nextDeviceNumber,
      rangeEnd: settings.nextDeviceNumber + rangeSize - 1,
      nextNumber: settings.nextDeviceNumber,
    };
    settings.nextDeviceNumber += rangeSize;
    await putRecord(tx, actor.organizationId, "settings", settings);
    await audit(
      tx,
      actor,
      "device-enrollment",
      device.id,
      "Offline enrollment",
      device,
    );
    return putRecord(
      tx,
      actor.organizationId,
      "device",
      device,
      actor.branchId,
    );
  });
  post("devices/:id", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const device = await scoped(tx, actor, "device", params.id);
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    if (body.offlineAllowed !== undefined)
      device.offlineAllowed = body.offlineAllowed === true;
    if (body.renewHours !== undefined)
      device.offlineUntil = new Date(
        Date.now() +
          integer(body.renewHours, "Renew hours", 1, settings.offlineHours) *
            3600000,
      ).toISOString();
    await audit(
      tx,
      actor,
      "device-policy",
      device.id,
      text(body.reason, "reason"),
      body,
    );
    return putRecord(
      tx,
      actor.organizationId,
      "device",
      device,
      actor.branchId,
    );
  });
  app.post("/api/v1/sync", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, ["owner", "manager", "cashier"]);
    const body = request.body;
    if (!Array.isArray(body.transactions) || body.transactions.length > 100)
      fail("Synchronize up to 100 transactions.");
    const results = [];
    for (const input of body.transactions) {
      const sale = { ...input, deviceId: body.deviceId, offline: true };
      const existing = (
        await records(db, actor.organizationId, "conflict", actor.branchId)
      ).find((item) => item.transactionId === sale.transactionId);
      if (existing) {
        results.push({
          transactionId: sale.transactionId,
          status: existing.status === "pending" ? "conflict" : existing.status,
          invoice: existing.invoice,
          conflictId: existing.id,
          error: existing.error,
        });
        continue;
      }
      try {
        const invoice = await db.transaction((tx) =>
          idempotent(tx, actor, sale.transactionId, sale, () =>
            finalizeSale(tx, actor, sale),
          ),
        );
        results.push({
          transactionId: sale.transactionId,
          status: "accepted",
          invoice,
        });
      } catch (error: any) {
        const conflict = await db.transaction(async (tx) => {
          const found = (
            await records(tx, actor.organizationId, "conflict", actor.branchId)
          ).find((item) => item.transactionId === sale.transactionId);
          if (found) return found;
          const item = {
            id: id("conflict"),
            branchId: actor.branchId,
            transactionId: sale.transactionId,
            actor,
            sale,
            status: "pending",
            error: error.message,
            createdAt: now(),
          };
          await audit(tx, actor, "sync-conflict", item.id, error.message);
          return putRecord(
            tx,
            actor.organizationId,
            "conflict",
            item,
            actor.branchId,
          );
        });
        results.push({
          transactionId: sale.transactionId,
          status: "conflict",
          conflictId: conflict.id,
          error: error.message,
        });
      }
    }
    return { results, serverTime: now() };
  });
  post("conflicts/:id/resolve", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const conflict = await scoped(tx, actor, "conflict", params.id);
    if (conflict.status !== "pending") return conflict;
    text(body.reason, "reconciliation reason");
    if (!["accept", "reject"].includes(body.action))
      fail("Choose accept or reject.");
    if (body.action === "accept")
      conflict.invoice = await idempotent(
        tx,
        actor,
        conflict.sale.transactionId,
        conflict.sale,
        () =>
          finalizeSale(
            tx,
            { ...conflict.actor, role: actor.role },
            conflict.sale,
            true,
          ),
      );
    conflict.status = body.action === "accept" ? "accepted" : "rejected";
    conflict.refundRequired = body.action === "reject";
    conflict.resolvedBy = actor.id;
    conflict.reason = body.reason;
    conflict.resolvedAt = now();
    await audit(tx, actor, "conflict-resolution", conflict.id, body.reason, {
      action: body.action,
      refundRequired: conflict.refundRequired,
    });
    return putRecord(
      tx,
      actor.organizationId,
      "conflict",
      conflict,
      actor.branchId,
    );
  });
  post("transfers", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const user = (await getRecord(tx, actor.organizationId, "user", actor.id))!;
    if (
      !user.branchIds.includes(body.destinationBranchId) ||
      body.destinationBranchId === actor.branchId
    )
      fail("Choose an authorized destination branch.", 403);
    text(body.reason, "transfer reason");
    if (!Array.isArray(body.lines) || !body.lines.length)
      fail("Add transfer lines.");
    const transferId = id("transfer");
    const lines = [];
    for (const input of body.lines) {
      const quantity = integer(input.quantity, "Transfer quantity", 1);
      const stock = (await inventory(tx, actor)).find(
        (item) =>
          item.productId === input.productId && item.binId === input.binId,
      );
      if (!stock || stock.available < quantity)
        fail("Insufficient available stock.", 409);
      const product = await scoped(tx, actor, "product", input.productId);
      const source = await scoped(tx, actor, "location", input.binId);
      if (source.kind !== "sellable")
        fail("Transfer available stock from a sellable bin.");
      if (product.serialTracked) {
        if (
          !Array.isArray(input.serials) ||
          input.serials.length !== quantity ||
          new Set(input.serials).size !== quantity
        )
          fail("Select a serial for each transferred unit.");
        for (const serial of input.serials) {
          const item = await scoped(
            tx,
            actor,
            "serial",
            product.id + ":" + serial,
          );
          if (item.status !== "available" || item.binId !== input.binId)
            fail("Serial is unavailable at source.");
          await putRecord(
            tx,
            actor.organizationId,
            "serial",
            { ...item, status: "in-transit", transferId },
            actor.branchId,
          );
        }
      }
      await adjust(
        tx,
        actor,
        input.productId,
        input.binId,
        -quantity,
        "Transfer dispatch",
        transferId,
      );
      lines.push({
        ...input,
        id: id("transfer-line"),
        quantity,
        received: 0,
        receivedSerials: [],
      });
    }
    const transfer = {
      id: transferId,
      branchId: actor.branchId,
      destinationBranchId: body.destinationBranchId,
      lines,
      reason: body.reason,
      status: "dispatched",
      createdAt: now(),
      userId: actor.id,
    };
    await audit(tx, actor, "transfer-dispatch", transferId, body.reason);
    return putRecord(
      tx,
      actor.organizationId,
      "transfer",
      transfer,
      actor.branchId,
    );
  });
  post("transfers/:id/receive", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const transfer = await getRecord(
      tx,
      actor.organizationId,
      "transfer",
      params.id,
    );
    if (!transfer || transfer.destinationBranchId !== actor.branchId)
      fail("Transfer is unavailable in this branch.", 404);
    if (!Array.isArray(body.lines) || !body.lines.length)
      fail("Add receipt lines.");
    for (const input of body.lines) {
      const candidates = transfer.lines.filter((line: any) =>
        input.lineId
          ? line.id === input.lineId
          : line.productId === input.productId,
      );
      if (candidates.length !== 1) fail("Select the exact transfer line.");
      const line = candidates[0];
      const quantity = integer(
        input.quantity,
        "Receipt quantity",
        1,
        line.quantity - line.received,
      );
      const product = await scoped(tx, actor, "product", line.productId);
      const bin = await scoped(tx, actor, "location", input.binId);
      if (bin.kind !== "sellable")
        fail("Receive transfer into a sellable bin.");
      if (product.serialTracked) {
        if (
          !Array.isArray(input.serials) ||
          input.serials.length !== quantity ||
          new Set(input.serials).size !== quantity
        )
          fail("Scan each received serial.");
        for (const serial of input.serials) {
          const item = await getRecord(
            tx,
            actor.organizationId,
            "serial",
            product.id + ":" + serial,
          );
          if (
            !item ||
            !line.serials.includes(serial) ||
            line.receivedSerials.includes(serial) ||
            item.status !== "in-transit" ||
            item.transferId !== transfer.id
          )
            fail("Serial does not belong to the pending transfer.");
          await putRecord(
            tx,
            actor.organizationId,
            "serial",
            {
              ...item,
              branchId: actor.branchId,
              binId: bin.id,
              status: "available",
              transferId: null,
            },
            actor.branchId,
          );
          line.receivedSerials.push(serial);
        }
      }
      await adjust(
        tx,
        actor,
        line.productId,
        input.binId,
        quantity,
        "Transfer receipt",
        transfer.id,
      );
      line.received += quantity;
    }
    transfer.status = transfer.lines.every(
      (line: any) => line.quantity === line.received,
    )
      ? "received"
      : "partial";
    await audit(
      tx,
      actor,
      "transfer-receipt",
      transfer.id,
      "Transfer received",
    );
    return putRecord(
      tx,
      actor.organizationId,
      "transfer",
      transfer,
      transfer.branchId,
    );
  });
  post("warranty-claims", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const returned = await scoped(tx, actor, "return", body.returnId);
    if (returned.condition !== "warranty") fail("Choose a warranty return.");
    await scoped(tx, actor, "supplier", body.supplierId);
    const previous = body.id
      ? await scoped(tx, actor, "warranty", body.id)
      : undefined;
    const claim = {
      ...previous,
      id: previous?.id || id("warranty"),
      branchId: actor.branchId,
      returnId: returned.id,
      supplierId: body.supplierId,
      reason: text(body.reason, "claim reason"),
      status: body.status || "open",
      createdAt: previous?.createdAt || now(),
      updatedAt: now(),
    };
    if (
      !["open", "sent", "approved", "rejected", "settled"].includes(
        claim.status,
      )
    )
      fail("Unknown warranty status.");
    await audit(tx, actor, "warranty", claim.id, claim.reason, {
      status: claim.status,
    });
    return putRecord(
      tx,
      actor.organizationId,
      "warranty",
      claim,
      actor.branchId,
    );
  });
  post("core-returns", async (tx, actor, body) => {
    return idempotent(tx, actor, body.transactionId, body, async () => {
      allow(actor, ["owner", "manager"]);
      const invoice = await scoped(tx, actor, "invoice", body.invoiceId);
      const originals = invoice.lines.filter(
        (line: any) => line.productId === body.productId && line.coreCharge > 0,
      );
      if (!originals.length)
        fail("This invoice has no core charge for that part.");
      const shift = (
        await records(tx, actor.organizationId, "shift", actor.branchId)
      ).find((item) => item.userId === actor.id && !item.closedAt);
      if (!shift) fail("Open your shift before recording a refund.", 409);
      const previous = (
        await records(tx, actor.organizationId, "coreReturn", actor.branchId)
      )
        .filter(
          (item) =>
            item.invoiceId === invoice.id && item.productId === body.productId,
        )
        .reduce((sum, item) => sum + item.quantity, 0);
      const quantity = integer(
        body.quantity,
        "Core return quantity",
        1,
        originals.reduce((sum: number, line: any) => sum + line.qty, 0) -
          previous,
      );
      if (!["Cash", "Card", "UPI"].includes(body.refundType || "Cash"))
        fail("Choose a supported refund method.");
      const entry = {
        id: id("core"),
        branchId: actor.branchId,
        invoiceId: invoice.id,
        productId: body.productId,
        quantity,
        total: quantity * originals[0].coreCharge,
        reason: text(body.reason, "reason"),
        refundType: body.refundType || "Cash",
        createdAt: now(),
        userId: actor.id,
        shiftId: shift.id,
      };
      await audit(tx, actor, "core-return", entry.id, entry.reason);
      return putRecord(
        tx,
        actor.organizationId,
        "coreReturn",
        entry,
        actor.branchId,
      );
    });
  });
  app.get("/api/v1/reports/:name", async (request: any, reply) => {
    const result = await db.readSnapshot((snapshot) => report(
      snapshot,
      request.actor,
      request.params.name,
      request.query,
    ));
    if (request.query.format === "csv") {
      const keys = [
        ...new Set(result.rows.flatMap((row: any) => Object.keys(row))),
      ];
      const escape = (value: any) => {
        const raw = value == null ? "" : typeof value === "object" ? JSON.stringify(value) : String(value);
        const cell = typeof value === "string" && /^(?:\s*[=+@-]|[\t\r\n])/.test(raw) ? `'${raw}` : raw;
        return `"${cell.replace(/"/g, '""')}"`;
      };
      const csv = [
        keys.map(escape).join(","),
        ...result.rows.map((row: any) =>
          keys.map((key) => escape(row[key])).join(","),
        ),
      ].join("\r\n");
      return reply
        .type("text/csv")
        .header(
          "Content-Disposition",
          `attachment; filename="${request.params.name}.csv"`,
        )
        .send(csv);
    }
    return result;
  });
  return app;
}
function validateFitment(rule: any) {
  text(rule.make, "make");
  text(rule.model, "model");
  integer(rule.yearFrom, "Start year", 1900, 2100);
  integer(rule.yearTo, "End year", rule.yearFrom, 2100);
  text(rule.source, "fitment source");
  for (const key of ["engine", "fuel", "trim", "drivetrain", "market"])
    if (rule[key] !== undefined) text(rule[key], key, false);
  if (rule.exclusions !== undefined && !Array.isArray(rule.exclusions))
    fail("Exclusions must be an array.");
  for (const key of ["effectiveFrom", "effectiveTo"])
    if (rule[key] && !/^\d{4}-\d{2}-\d{2}$/.test(rule[key]))
      fail("Effective dates must use YYYY-MM-DD.");
}
function fitmentKey(rule: any) {
  return [
    "productId",
    "make",
    "model",
    "yearFrom",
    "yearTo",
    "engine",
    "fuel",
    "trim",
    "drivetrain",
    "market",
  ]
    .map((key) => normalize(rule[key]))
    .join("|");
}
function withoutCost(value: any): any {
  if (Array.isArray(value)) return value.map(withoutCost);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => key !== "cost")
        .map(([key, entry]) => [key, withoutCost(entry)]),
    );
  return value;
}
