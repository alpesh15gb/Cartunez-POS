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
// Security: failures count within this window; a counter that sees this many
// wrong PINs (for anyone) in the window stops PIN sign-in for a while.
export const PIN_WINDOW_MINUTES = 15;
export const PIN_DEVICE_MAX_FAILURES = 15;
export const PIN_DEVICE_LOCK_MINUTES = 15;
/** PIN sessions are shorter than password sessions: settings.pinSessionHours, default 12, never above sessionHours. */
export function pinSessionHours(settings: RecordData | undefined) {
  const session = Number(settings?.sessionHours) > 0 ? Number(settings!.sessionHours) : 12;
  const configured = Number(settings?.pinSessionHours);
  return Math.min(session, configured > 0 ? configured : 12);
}

/** Reads (creating if needed) an attempt record and holds a row lock on it until the transaction ends. */
async function lockedRecord(tx: Database, org: string, kind: string, id: string): Promise<RecordData> {
  await tx.query(
    "INSERT INTO records(id,organization_id,branch_id,kind,data) VALUES($1,$2,'',$3,$4) ON CONFLICT(organization_id,kind,id) DO NOTHING",
    [id, org, kind, JSON.stringify({ id, failures: 0, lockedUntil: null })],
  );
  const row = await tx.query(
    "SELECT data FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3 FOR UPDATE",
    [org, kind, id],
  );
  return row.rows[0].data;
}

/**
 * Security: a PIN session lives only while its counter is still a PIN counter
 * of the token's branch with the same key it was issued under (switching a
 * counter off, or re-issuing its key, ends its sessions).
 */
export async function pinSessionActive(db: Database, claims: any) {
  if (typeof claims.deviceId !== "string") return false;
  const key = await getRecord(db, claims.organizationId, "devicePinKey", claims.deviceId);
  const device = await getRecord(db, claims.organizationId, "device", claims.deviceId);
  if (!key?.active || !device || device.branchId !== claims.branchId || key.branchId !== claims.branchId) return false;
  // The token names the key it was issued under, so a re-issued key ends older sessions.
  return typeof claims.pinKey === "string" && claims.pinKey === keyFingerprint(key);
}

/** A short, non-secret tag of a counter key (a slice of its stored hash, re-hashed). */
const keyFingerprint = (key: RecordData) =>
  createHash("sha256").update("pin-session:" + String(key.keyHash)).digest("hex").slice(0, 16);
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
  // Security: the counter picks the person by id before the PIN is checked, so
  // PINs need not be unique — refusing a PIN "someone else uses" told a manager
  // another person's PIN. Strictly rate limited.
  app.post(
    "/api/v1/users/:id/pin",
    { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
    async (request: any) =>
      db.transaction(async (tx) => {
        const actor: Actor = request.actor;
        const body = request.body || {};
        allow(actor, ["owner", "manager"]);
        const user = await getRecord(tx, actor.organizationId, "user", String(request.params.id));
        if (!user || !user.branchIds.includes(actor.branchId)) fail("Staff member not found in this branch.", 404);
        if (!pinRoles.includes(user.role)) fail("Owners sign in with email and password, not a PIN.");
        if (actor.role === "manager" && user.id !== actor.id && user.role === "manager")
          fail("Only the owner can set another manager's PIN.", 403);
        if (body.clear === true) delete user.pinHash;
        else user.pinHash = hashPassword(validPin(body.pin));
        await putRecord(tx, actor.organizationId, "user", user);
        await putRecord(tx, actor.organizationId, "pinLock", { id: user.id, failures: 0, lockedUntil: null });
        await audit(tx, actor, body.clear === true ? "pin-clear" : "pin-set", user.id,
          body.clear === true ? "PIN sign-in removed" : "PIN set for counter sign-in");
        return publicUser(user);
      }),
  );

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
        const { device, key } = await pinCounter(tx, org, body.deviceId, body.deviceKey);
        const userId = text(body.userId, "staff member", true, 128);
        const user = await getRecord(tx, org, "user", userId);
        if (!user || !user.active || !pinRoles.includes(user.role) || !user.branchIds.includes(device.branchId) ||
          typeof user.pinHash !== "string")
          return { error: "This person cannot sign in with a PIN on this counter.", status: 403 };
        // Security: lock the counter's and the person's attempt records (always in
        // this order) for the rest of the transaction, so concurrent guesses
        // cannot all read the same failure count.
        const deviceLock = await lockedRecord(tx, org, "pinDeviceLock", device.id);
        const lock = await lockedRecord(tx, org, "pinLock", user.id);
        const counter = deviceActor(org, device);
        const at = Date.now();
        const waitMessage = (until: string, who: string) => {
          const minutes = Math.max(1, Math.ceil((Date.parse(until) - at) / 60000));
          return `Too many wrong PINs${who}. Try again in ${minutes} minute${minutes === 1 ? "" : "s"}, or sign in with email.`;
        };
        if (deviceLock.lockedUntil && Date.parse(deviceLock.lockedUntil) > at)
          return { error: waitMessage(deviceLock.lockedUntil, " on this counter"), status: 429 };
        if (lock.lockedUntil && Date.parse(lock.lockedUntil) > at)
          return { error: waitMessage(lock.lockedUntil, ""), status: 429 };
        const pin = typeof body.pin === "string" && /^\d{4,6}$/.test(body.pin) ? body.pin : "";
        if (!pin || !validPassword(pin, user.pinHash)) {
          // Failures count within a window, per person and per counter.
          const windowStart = at - PIN_WINDOW_MINUTES * 60000;
          if (!lock.windowStart || Date.parse(lock.windowStart) < windowStart) {
            lock.windowStart = new Date(at).toISOString();
            lock.failures = 0;
          }
          if (!deviceLock.windowStart || Date.parse(deviceLock.windowStart) < windowStart) {
            deviceLock.windowStart = new Date(at).toISOString();
            deviceLock.failures = 0;
          }
          lock.failures = (lock.failures || 0) + 1;
          deviceLock.failures = (deviceLock.failures || 0) + 1;
          const locked = lock.failures >= PIN_MAX_FAILURES;
          if (locked) {
            lock.lockedUntil = new Date(at + PIN_LOCK_MINUTES * 60000).toISOString();
            lock.failures = 0;
            lock.windowStart = null;
          }
          const counterLocked = deviceLock.failures >= PIN_DEVICE_MAX_FAILURES;
          if (counterLocked) {
            deviceLock.lockedUntil = new Date(at + PIN_DEVICE_LOCK_MINUTES * 60000).toISOString();
            deviceLock.failures = 0;
            deviceLock.windowStart = null;
            await audit(tx, counter, "pin-counter-lockout", device.id,
              `PIN sign-in on this counter locked for ${PIN_DEVICE_LOCK_MINUTES} minutes after ${PIN_DEVICE_MAX_FAILURES} wrong PINs`);
          }
          await putRecord(tx, org, "pinDeviceLock", deviceLock);
          await putRecord(tx, org, "pinLock", lock);
          await audit(tx, counter, locked ? "pin-lockout" : "pin-failed", user.id,
            locked ? `PIN sign-in locked for ${PIN_LOCK_MINUTES} minutes after ${PIN_MAX_FAILURES} wrong PINs` : "Wrong PIN entered",
            { deviceId: device.id });
          if (locked) return { error: `Too many wrong PINs. PIN sign-in is locked for ${PIN_LOCK_MINUTES} minutes.`, status: 429 };
          if (counterLocked)
            return { error: `Too many wrong PINs on this counter. PIN sign-in is locked for ${PIN_DEVICE_LOCK_MINUTES} minutes.`, status: 429 };
          return { error: `Wrong PIN. ${PIN_MAX_FAILURES - lock.failures} tries left.`, status: 401 };
        }
        if (lock.failures || lock.lockedUntil) await putRecord(tx, org, "pinLock", { id: user.id, failures: 0, lockedUntil: null });
        await audit(tx, { ...counter, id: user.id, name: user.name, role: user.role }, "pin-login", user.id,
          "Signed in with PIN", { deviceId: device.id });
        return { user, device, key };
      });
      if ("error" in outcome) fail(outcome.error as string, outcome.status as number);
      const { user, device, key } = outcome as { user: RecordData; device: RecordData; key: RecordData };
      const settings = (await getRecord(db, org, "settings", "settings"))!;
      const hours = pinSessionHours(settings);
      const token = jwt.sign(
        { sub: user.id, organizationId: org, branchId: device.branchId, authVersion: user.authVersion || 0, deviceId: device.id, pin: true,
          pinKey: keyFingerprint(key) },
        configuration.jwtSecret,
        { expiresIn: Math.round(hours * 3600), algorithm: "HS256" },
      );
      return {
        token,
        user: publicUser(user),
        branchId: device.branchId,
        organizationId: org,
        expiresAt: new Date(Date.now() + hours * 3600000).toISOString(),
        deviceId: device.id,
      };
    },
  );
}
