// WS-D: PIN sign-in for counter staff on enrolled counters.
//
// * An owner or manager sets a 4–6 digit PIN on a staff account (stored as a
//   slow scrypt hash, like passwords; never returned by any route).
// * An owner or manager turns a counter (an enrolled device of their branch)
//   into a PIN counter: the server issues a random device key once, keeps only
//   its SHA-256, and the counter stores the key locally.
// * The counter lists the branch's staff who have a PIN and signs them in with
//   device key + user + PIN. Five wrong PINs lock that person's PIN sign-in for
//   five minutes; every failure and lockout is audited.
import type { FastifyInstance } from "fastify";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import jwt from "jsonwebtoken";
import type { Database, RecordData } from "../db.js";
import type { Post } from "./types.js";
import { records, getRecord, putRecord } from "../db.js";
import { type Actor, allow, scoped, text, fail, now, audit, hashPassword, validPassword } from "../domain.js";
import { runtimeConfig } from "../config.js";

export const PIN_MAX_FAILURES = 5;
export const PIN_LOCK_MINUTES = 5;
/** Roles that may sign in with a PIN. Owners always use email and password. */
const pinRoles = ["manager", "cashier", "inventory"];

/** A user record as any client may see it: no password or PIN hash. */
export function publicUser(user: RecordData): RecordData & { hasPin: boolean } {
  const { passwordHash, pinHash, ...rest } = user;
  return { ...rest, hasPin: typeof pinHash === "string" && pinHash.length > 0 };
}

export function validPin(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4,6}$/.test(value))
    fail("PIN must be 4 to 6 digits.");
  if (/^(\d)\1+$/.test(value) || "0123456789".includes(value) || "9876543210".includes(value))
    fail("Choose a PIN that is harder to guess than repeated or consecutive digits.");
  return value;
}

const sha256 = (value: string) => createHash("sha256").update(value).digest();

/** The PIN counter and its device record, or a 401 when the key is wrong or switched off. */
async function pinCounter(db: Database, organizationId: string, deviceId: unknown, deviceKey: unknown) {
  if (typeof deviceId !== "string" || typeof deviceKey !== "string" || deviceKey.length > 200)
    fail("This counter is not set up for PIN sign-in. Sign in with email.", 401);
  const key = await getRecord(db, organizationId, "devicePinKey", deviceId);
  const device = await getRecord(db, organizationId, "device", deviceId);
  if (
    !key?.active ||
    !device ||
    device.branchId !== key.branchId ||
    !timingSafeEqual(sha256(deviceKey), Buffer.from(String(key.keyHash), "hex"))
  )
    fail("This counter is not set up for PIN sign-in. Sign in with email.", 401);
  return { key, device };
}

function deviceActor(organizationId: string, device: RecordData): Actor {
  return {
    id: "device:" + device.id,
    name: String(device.name || "Counter"),
    role: "device",
    organizationId,
    branchId: device.branchId,
  };
}

export function pinRoutes(app: FastifyInstance, db: Database, post: Post) {
  const configuration = runtimeConfig();
  const organization = (body: any) =>
    text(body.organizationId || (configuration.production ? "" : "demo"), "organization code", true, 64);

  // Set or clear a staff member's PIN.
  post("users/:id/pin", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const user = await getRecord(tx, actor.organizationId, "user", params.id);
    if (!user || !user.branchIds.includes(actor.branchId)) fail("Staff member not found in this branch.", 404);
    if (!pinRoles.includes(user.role)) fail("Owners sign in with email and password, not a PIN.");
    if (actor.role === "manager" && user.id !== actor.id && user.role === "manager")
      fail("Only the owner can set another manager's PIN.", 403);
    if (body.clear === true) {
      delete user.pinHash;
    } else {
      const pin = validPin(body.pin);
      // PINs identify a person on a shared counter, so two people in the branch must not share one.
      const branchUsers = (await records(tx, actor.organizationId, "user")).filter(
        (other) => other.id !== user.id && other.active && other.branchIds.some((b: string) => user.branchIds.includes(b)),
      );
      if (branchUsers.some((other) => typeof other.pinHash === "string" && validPassword(pin, other.pinHash)))
        fail("Someone else in this branch already uses that PIN. Choose another.", 409);
      user.pinHash = hashPassword(pin);
    }
    await putRecord(tx, actor.organizationId, "user", user);
    await putRecord(tx, actor.organizationId, "pinLock", { id: user.id, failures: 0, lockedUntil: null });
    await audit(tx, actor, body.clear === true ? "pin-clear" : "pin-set", user.id,
      body.clear === true ? "PIN sign-in removed" : "PIN set for counter sign-in");
    return publicUser(user);
  });

  // Turn an enrolled device of this branch into a PIN counter (or switch it off).
  post("devices/:id/pin-key", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const device = await scoped(tx, actor, "device", params.id);
    if (body.disable === true) {
      const existing = await getRecord(tx, actor.organizationId, "devicePinKey", device.id);
      if (existing) {
        existing.active = false;
        existing.disabledAt = now();
        existing.disabledBy = actor.id;
        await putRecord(tx, actor.organizationId, "devicePinKey", existing, actor.branchId);
      }
      await audit(tx, actor, "pin-counter-off", device.id, "PIN sign-in switched off for this counter");
      return { deviceId: device.id, active: false };
    }
    const key = randomBytes(32).toString("base64url");
    await putRecord(tx, actor.organizationId, "devicePinKey", {
      id: device.id,
      deviceId: device.id,
      branchId: device.branchId,
      keyHash: sha256(key).toString("hex"),
      active: true,
      createdAt: now(),
      createdBy: actor.id,
    }, actor.branchId);
    await audit(tx, actor, "pin-counter-on", device.id, "PIN sign-in switched on for this counter");
    // The only time the key leaves the server.
    return { deviceId: device.id, deviceName: device.name, branchId: device.branchId, organizationId: actor.organizationId, key, active: true };
  });

  // Staff tiles for the PIN counter's sign-in screen.
  app.post(
    "/api/v1/auth/pin-staff",
    { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } },
    async (request: any) => {
      const body = request.body || {};
      const org = organization(body);
      const { device } = await pinCounter(db, org, body.deviceId, body.deviceKey);
      const branch = await getRecord(db, org, "branch", device.branchId);
      const staff = (await records(db, org, "user"))
        .filter((user) => user.active && pinRoles.includes(user.role) && user.branchIds.includes(device.branchId) &&
          typeof user.pinHash === "string")
        .map((user) => ({ id: user.id, name: user.name, role: user.role }))
        .sort((a, b) => String(a.name).localeCompare(String(b.name)));
      return { organizationId: org, branchId: device.branchId, branchName: branch?.name || device.branchId,
        deviceId: device.id, deviceName: device.name, staff };
    },
  );

  app.post(
    "/api/v1/auth/pin-login",
    { config: { rateLimit: { max: 20, timeWindow: "1 minute" } } },
    async (request: any) => {
      const body = request.body || {};
      const org = organization(body);
      const outcome = await db.transaction(async (tx) => {
        const { device } = await pinCounter(tx, org, body.deviceId, body.deviceKey);
        const userId = text(body.userId, "staff member", true, 128);
        const user = await getRecord(tx, org, "user", userId);
        if (!user || !user.active || !pinRoles.includes(user.role) || !user.branchIds.includes(device.branchId) ||
          typeof user.pinHash !== "string")
          return { error: "This person cannot sign in with a PIN on this counter.", status: 403 };
        const lock = (await getRecord(tx, org, "pinLock", user.id)) || { id: user.id, failures: 0, lockedUntil: null };
        const counter = deviceActor(org, device);
        if (lock.lockedUntil && Date.parse(lock.lockedUntil) > Date.now()) {
          const minutes = Math.max(1, Math.ceil((Date.parse(lock.lockedUntil) - Date.now()) / 60000));
          return { error: `Too many wrong PINs. Try again in ${minutes} minute${minutes === 1 ? "" : "s"}, or sign in with email.`, status: 429 };
        }
        const pin = typeof body.pin === "string" && /^\d{4,6}$/.test(body.pin) ? body.pin : "";
        if (!pin || !validPassword(pin, user.pinHash)) {
          lock.failures = (lock.failures || 0) + 1;
          const locked = lock.failures >= PIN_MAX_FAILURES;
          if (locked) {
            lock.lockedUntil = new Date(Date.now() + PIN_LOCK_MINUTES * 60000).toISOString();
            lock.failures = 0;
          }
          await putRecord(tx, org, "pinLock", lock);
          await audit(tx, counter, locked ? "pin-lockout" : "pin-failed", user.id,
            locked ? `PIN sign-in locked for ${PIN_LOCK_MINUTES} minutes after ${PIN_MAX_FAILURES} wrong PINs` : "Wrong PIN entered",
            { deviceId: device.id });
          return locked
            ? { error: `Too many wrong PINs. PIN sign-in is locked for ${PIN_LOCK_MINUTES} minutes.`, status: 429 }
            : { error: `Wrong PIN. ${PIN_MAX_FAILURES - lock.failures} tries left.`, status: 401 };
        }
        if (lock.failures || lock.lockedUntil) await putRecord(tx, org, "pinLock", { id: user.id, failures: 0, lockedUntil: null });
        await audit(tx, { ...counter, id: user.id, name: user.name, role: user.role }, "pin-login", user.id,
          "Signed in with PIN", { deviceId: device.id });
        return { user, device };
      });
      if ("error" in outcome) fail(outcome.error as string, outcome.status as number);
      const { user, device } = outcome as { user: RecordData; device: RecordData };
      const settings = (await getRecord(db, org, "settings", "settings"))!;
      const token = jwt.sign(
        { sub: user.id, organizationId: org, branchId: device.branchId, authVersion: user.authVersion || 0, deviceId: device.id, pin: true },
        configuration.jwtSecret,
        { expiresIn: settings.sessionHours * 3600, algorithm: "HS256" },
      );
      return {
        token,
        user: publicUser(user),
        branchId: device.branchId,
        organizationId: org,
        expiresAt: new Date(Date.now() + settings.sessionHours * 3600000).toISOString(),
        deviceId: device.id,
      };
    },
  );
}
