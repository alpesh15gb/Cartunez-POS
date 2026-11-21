import Fastify from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import jwt from "jsonwebtoken";
import type { Database } from "./db.js";
import { records, getRecord } from "./db.js";
import { type Actor, text, fail, validPassword, idempotent } from "./domain.js";
import { magentoRoutes } from "./magento.js";
import { magentoOrderRoutes } from "./magento-orders.js";
import { productImageRoutes } from "./product-images.js";
import { purchasingRoutes } from "./purchasing.js";
import { magentoCheckRoutes } from "./magento-check.js";
import { runtimeConfig } from "./config.js";
import type { Post } from "./routes/types.js";
import { bootstrapRoutes } from "./routes/bootstrap.js";
import { userRoutes } from "./routes/users.js";
import { settingsRoutes } from "./routes/settings.js";
import { catalogRoutes } from "./routes/catalog.js";
import { inventoryRoutes, transferRoutes } from "./routes/inventory.js";
import { purchaseOrderRoutes } from "./routes/purchase-orders.js";
import { shiftRoutes } from "./routes/shifts.js";
import { salesRoutes } from "./routes/sales.js";
// WS-A: parked sales (holds) with label / customer name / vehicle reg no.
import { holdRoutes } from "./routes/holds.js";
import { deviceRoutes } from "./routes/devices.js";
import { warrantyRoutes } from "./routes/warranty.js";
import { reportRoutes } from "./routes/reports.js";
import { pinRoutes } from "./routes/auth-pin.js"; // WS-D
// WS-B: returns, customers and their checkout hooks (hooks register on import).
import { returnRoutes } from "./returns.js";
import { customerRoutes } from "./routes/customers.js";
import "./hooks/exchange.js";
import "./hooks/credit-limit.js";
import "./hooks/advance.js";
// WS-F: owner command center and accounting exports.
import { dashboardRoutes } from "./routes/dashboard.js";
import { exportRoutes } from "./exports/routes.js";
import { fulfilmentRoutes } from "./fulfilment.js"; // WS-E: online order fulfilment

export type { Post } from "./routes/types.js";

const permittedOrigins = [
  "http://localhost:3000",
  "http://127.0.0.1:3000",
  "https://localhost",
  "http://localhost",
  "capacitor://localhost",
  "motorline://app",
];
export async function createApp(db: Database, options: { fetch?: typeof globalThis.fetch } = {}) {
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
      version: "1.2.0",
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
      const { passwordHash, pinHash, ...publicUser } = user; // WS-D: never return the PIN hash
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
      /\/auth\/pin-(staff|login)$/.test(request.url.split("?")[0]) || // WS-D: PIN counter sign-in
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
  bootstrapRoutes(app, db);
  const post: Post = (
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
          path === "shifts/:id/cash-movements" ||
          path.startsWith("inventory/count") ||
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
  userRoutes(app, db, post);
  magentoRoutes(app, db, post, () => options.fetch || globalThis.fetch);
  magentoOrderRoutes(app, db, post, () => options.fetch || globalThis.fetch);
  productImageRoutes(app, db, post);
  purchasingRoutes(app, db, post);
  magentoCheckRoutes(app, db, () => options.fetch || globalThis.fetch);
  settingsRoutes(app, db, post);
  catalogRoutes(app, db, post);
  inventoryRoutes(app, db, post);
  purchaseOrderRoutes(app, db, post);
  shiftRoutes(app, db, post);
  salesRoutes(app, db, post);
  holdRoutes(app, db, post); // WS-A
  deviceRoutes(app, db, post);
  transferRoutes(app, db, post);
  warrantyRoutes(app, db, post);
  reportRoutes(app, db);
  pinRoutes(app, db, post); // WS-D
  returnRoutes(app, db); // WS-B
  customerRoutes(app, db, post); // WS-B
  // WS-F
  dashboardRoutes(app, db);
  exportRoutes(app, db);
  fulfilmentRoutes(app, db, post, () => options.fetch || globalThis.fetch); // WS-E
  return app;
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
