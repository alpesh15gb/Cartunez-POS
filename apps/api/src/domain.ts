import { queueMagentoSync } from "./online-queue.js";
import {
  createHash,
  randomUUID,
  scryptSync,
  timingSafeEqual,
  randomBytes,
} from "node:crypto";
import type { Database, RecordData } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";

export const id = (prefix = "id") => `${prefix}-${randomUUID()}`;
export const now = () => new Date().toISOString();
/**
 * Online only: a part listed only on the website (shop.cartunez.in) and ordered
 * from the supplier when a customer buys it. It is never shop stock: no bins,
 * stock movements, valuation, counts, transfers or counter sales.
 */
export const ONLINE_ONLY_MESSAGE = "Online only — sold on the website";
/** A part that carries shop stock (not a service / kit, not an online-only part). */
export const holdsStock = (product: any) => !!product && product.type !== "service" && !product.onlineOnly;
export function fail(message: string, statusCode = 400): never {
  throw Object.assign(new Error(message), { statusCode });
}
export function integer(
  value: any,
  label: string,
  min = 0,
  max = 100000000000,
): number {
  const number =
    typeof value === "number" ||
    (typeof value === "string" && /^-?\d+$/.test(value))
      ? Number(value)
      : NaN;
  if (
    !Number.isSafeInteger(number) ||
    number < min ||
    number > max ||
    value === "" ||
    value == null
  )
    fail(`${label} must be an integer between ${min} and ${max}.`);
  return number;
}
export function text(
  value: any,
  label: string,
  required = true,
  max = 200,
): string {
  if (
    typeof value !== "string" ||
    value.length > max ||
    /[\x00-\x1f]/.test(value) ||
    (required && !value.trim())
  )
    fail(`Enter a valid ${label}.`);
  return value.trim();
}
export const normalize = (value: any) =>
  String(value ?? "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
export function barcodeKey(code: string) {
  if (![8, 12, 13, 14].includes(code.length) || !/^\d+$/.test(code)) return code;
  const digits = [...code].map(Number);
  const check = digits.pop();
  const sum = digits.reverse().reduce((total, digit, index) => total + digit * (index % 2 === 0 ? 3 : 1), 0);
  return (10 - sum % 10) % 10 === check ? code.padStart(14, "0") : code;
}
export function multiline(
  value: unknown,
  label: string,
  required = false,
  max = 1000,
): string {
  if (
    typeof value !== "string" ||
    value.length > max ||
    /[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]/.test(value) ||
    /\r(?!\n)/.test(value) ||
    (required && !value.trim())
  )
    fail(`Enter a valid ${label}.`);
  return value.replace(/\r\n/g, "\n").trim();
}
export function roundRatio(
  value: number,
  numerator: number,
  denominator: number,
): number {
  if (value < 0) return -roundRatio(-value, numerator, denominator);
  return Number(
    (BigInt(value) * BigInt(numerator) + BigInt(Math.floor(denominator / 2))) /
      BigInt(denominator),
  );
}
export function hashPassword(password: string) {
  const salt = randomBytes(16).toString("hex");
  return `${salt}:${scryptSync(password, salt, 64).toString("hex")}`;
}
export function validPassword(password: string, stored: string) {
  if (
    typeof stored !== "string" ||
    !/^[0-9a-f]{32}:[0-9a-f]{128}$/.test(stored) ||
    password.length > 256
  )
    return false;
  const [salt, hash] = stored.split(":");
  return timingSafeEqual(
    scryptSync(password, salt, 64),
    Buffer.from(hash, "hex"),
  );
}
export interface Actor {
  id: string;
  organizationId: string;
  branchId: string;
  role: string;
  name: string;
}
export function allow(actor: Actor, roles: string[]) {
  if (!roles.includes(actor.role))
    fail("Your role does not permit this action.", 403);
}
export async function scoped(
  db: Database,
  actor: Actor,
  kind: string,
  recordId: string,
) {
  const data = await getRecord(db, actor.organizationId, kind, recordId);
  if (!data || (data.branchId && data.branchId !== actor.branchId))
    fail(`${kind} is unavailable in this branch.`, 404);
  return data;
}
export async function audit(
  db: Database,
  actor: Actor,
  action: string,
  subject: string,
  reason: string,
  details: any = {},
) {
  return putRecord(
    db,
    actor.organizationId,
    "audit",
    {
      id: id("audit"),
      branchId: actor.branchId,
      userId: actor.id,
      action,
      subject,
      reason,
      details,
      createdAt: now(),
    },
    actor.branchId,
  );
}
export async function adjust(
  db: Database,
  actor: Actor,
  productId: string,
  binId: string,
  quantity: number,
  reason: string,
  referenceId: string,
  allowNegative = false,
) {
  const product = await scoped(db, actor, "product", productId);
  // Online-only parts never carry shop stock.
  if (product.onlineOnly)
    fail(`${product.name}: ${ONLINE_ONLY_MESSAGE}. It carries no shop stock.`, 409);
  const bin = await scoped(db, actor, "location", binId);
  const old = await db.query(
    "SELECT quantity FROM stock WHERE organization_id=$1 AND branch_id=$2 AND product_id=$3 AND bin_id=$4",
    [actor.organizationId, actor.branchId, productId, binId],
  );
  const current = Number(old.rows[0]?.quantity || 0);
  integer(quantity, "Stock change", -100000000000, 100000000000);
  integer(current + quantity, "Resulting stock", -100000000000, 100000000000);
  if (!allowNegative && current + quantity < 0)
    fail(
      `Insufficient stock for ${product.sku} at ${bin.rack}/${bin.shelf}/${bin.bin}.`,
      409,
    );
  await db.query(
    "INSERT INTO stock(organization_id,branch_id,product_id,bin_id,quantity) VALUES($1,$2,$3,$4,$5) ON CONFLICT(organization_id,branch_id,product_id,bin_id) DO UPDATE SET quantity=stock.quantity+excluded.quantity",
    [actor.organizationId, actor.branchId, productId, binId, quantity],
  );
  await db.query(
    "INSERT INTO stock_ledger(id,organization_id,branch_id,product_id,bin_id,quantity,reason,reference_id,user_id,cost) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
    [
      id("movement"),
      actor.organizationId,
      actor.branchId,
      productId,
      binId,
      quantity,
      reason,
      referenceId,
      actor.id,
      product.cost,
    ],
  );
  // Keep the website's stock in step (only for the branch that sells online).
  await queueMagentoSync(db, actor.organizationId, [productId], reason, actor.branchId);
}
/**
 * Integration: a counter hold past its `expiresAt` no longer reserves stock
 * (it stays listed until resumed or discarded). Job-card holds never expire.
 */
export function holdReserves(hold: RecordData, at = Date.now()) {
  return !hold.expiresAt || !(Date.parse(hold.expiresAt) <= at);
}
/**
 * Units of a part a parked sale's lines reserve in one bin: plain lines plus
 * the stocked components reserved for its kit lines (`line.components`, set by
 * the hold and job routes through hooks/kits.ts reserveKitComponents).
 */
export function heldUnits(lines: any[] | undefined, productId: string, binId: string) {
  let units = 0;
  for (const line of lines || []) {
    if (line.productId === productId && line.binId === binId) units += Number(line.qty) || 0;
    for (const component of Array.isArray(line.components) ? line.components : [])
      if (component.productId === productId && component.binId === binId) units += Number(component.qty) || 0;
  }
  return units;
}
/** Parked sales (of a branch) that still reserve stock. */
export async function reservingHolds(db: Database, organizationId: string, branchId?: string) {
  return (await records(db, organizationId, "hold", branchId)).filter((hold) => holdReserves(hold));
}
export async function inventory(db: Database, actor: Actor) {
  const holds = await reservingHolds(db, actor.organizationId, actor.branchId);
  const rows = (
    await db.query(
      "SELECT product_id,bin_id,quantity FROM stock WHERE organization_id=$1 AND branch_id=$2 ORDER BY product_id,bin_id",
      [actor.organizationId, actor.branchId],
    )
  ).rows;
  // Units held for open Magento orders, taken from the fullest sellable bins first.
  const online = new Map<string, number>();
  for (const order of await records(db, actor.organizationId, "onlineOrder", actor.branchId))
    for (const line of order.lines || [])
      if (line.productId && !line.onlineOnly)
        online.set(line.productId, (online.get(line.productId) || 0) + Number(line.reserved || 0) + Number(line.awaiting || 0));
  const sellable = new Set(
    (await records(db, actor.organizationId, "location", actor.branchId)).filter((b) => b.kind === "sellable").map((b) => b.id),
  );
  const parkedByBin = new Map<string, number>();
  for (const hold of holds) {
    for (const line of hold.cart.lines) {
      const key = line.productId + "|" + line.binId;
      parkedByBin.set(key, (parkedByBin.get(key) || 0) + line.qty);
      // A parked kit reserves its stocked components.
      for (const component of Array.isArray(line.components) ? line.components : []) {
        if (!component.binId) continue;
        const part = component.productId + "|" + component.binId;
        parkedByBin.set(part, (parkedByBin.get(part) || 0) + (Number(component.qty) || 0));
      }
    }
  }
  const stock = rows.map((row) => {
    const quantity = Number(row.quantity);
    const reserved = parkedByBin.get(row.product_id + "|" + row.bin_id) || 0;
    return { productId: row.product_id, binId: row.bin_id, quantity, reserved, available: quantity - reserved };
  });
  const candidates = stock.filter((row) => sellable.has(row.binId) && row.available > 0)
    .sort((a, b) => b.available - a.available || a.binId.localeCompare(b.binId));
  for (const row of candidates) {
    const remaining = online.get(row.productId) || 0;
    const allocated = Math.min(remaining, row.available);
    row.reserved += allocated;
    row.available -= allocated;
    online.set(row.productId, remaining - allocated);
  }
  return stock;
}
export function fitment(
  product: RecordData,
  vehicle?: RecordData,
  effectiveDate = now().slice(0, 10),
) {
  if (product.universal || product.type === "service") return { status: "universal", missing: [] };
  // Without a vehicle there is nothing to verify, so the sale is not a fitment override.
  if (!vehicle) return { status: "unchecked", missing: [] };
  const rules = (product.fitments || []).filter(
    (rule: any) =>
      (!rule.effectiveFrom || rule.effectiveFrom <= effectiveDate) &&
      (!rule.effectiveTo || rule.effectiveTo >= effectiveDate),
  );
  if (!rules.length) return { status: "unverified", missing: [] };
  const candidates = rules.filter(
    (rule: any) =>
      normalize(rule.make) === normalize(vehicle.make) &&
      normalize(rule.model) === normalize(vehicle.model) &&
      Number(vehicle.year) >= rule.yearFrom &&
      Number(vehicle.year) <= rule.yearTo,
  );
  if (!candidates.length) return { status: "incompatible", missing: [] };
  const missing = new Set<string>();
  for (const rule of candidates) {
    let matches = true;
    for (const key of ["engine", "fuel", "trim", "drivetrain", "market"]) {
      if (rule[key] && !vehicle[key]) {
        missing.add(key);
        matches = false;
      } else if (rule[key] && normalize(rule[key]) !== normalize(vehicle[key]))
        matches = false;
    }
    if (
      (rule.exclusions || []).some(
        (excluded: any) =>
          typeof excluded === "object" &&
          Object.entries(excluded).every(
            ([key, value]) => normalize(vehicle[key]) === normalize(value),
          ),
      )
    )
      matches = false;
    if (matches) return { status: "compatible", missing: [] };
  }
  return {
    status: missing.size ? "unverified" : "incompatible",
    missing: [...missing],
  };
}
export async function approved(
  db: Database,
  actor: Actor,
  action: string,
  approvalId: string | undefined,
  transactionId: string,
  // Security: what is being done — the amount (paise, or units for a stock
  // adjustment) and the invoice / customer / part it is done to.
  bound: { amount?: number; subjectId?: string | null } = {},
) {
  if (["owner", "manager"].includes(actor.role)) return;
  if (!approvalId) fail(`Manager approval is required for ${action}.`, 403);
  const approval = await scoped(db, actor, "approval", String(approvalId));
  if (
    approval.action !== action ||
    approval.transactionId !== transactionId ||
    approval.used ||
    new Date(approval.expiresAt).getTime() < Date.now()
  )
    fail("Approval is invalid or expired.", 403);
  if (typeof approval.amount === "number" && "amount" in bound) {
    const requested = Number(bound.amount);
    if (!Number.isFinite(requested) || requested > approval.amount)
      fail("This approval does not cover that amount. Ask the manager for a new approval.", 403);
  }
  if (approval.subjectId && "subjectId" in bound && approval.subjectId !== (bound.subjectId || null))
    fail(`This approval is for ${approval.subjectLabel || "something else"}, not this one.`, 403);
  approval.used = true;
  await putRecord(
    db,
    actor.organizationId,
    "approval",
    approval,
    actor.branchId,
  );
}
export async function idempotent(
  db: Database,
  actor: Actor,
  transactionId: any,
  body: any,
  action: () => Promise<any>,
) {
  text(transactionId, "transaction ID", true, 100);
  const hash = createHash("sha256").update(JSON.stringify(body)).digest("hex");
  const found = (
    await db.query(
      "SELECT request_hash,result FROM transactions WHERE organization_id=$1 AND transaction_id=$2",
      [actor.organizationId, transactionId],
    )
  ).rows[0];
  if (found) {
    if (hash !== found.request_hash)
      fail("Transaction ID was already used with a different payload.", 409);
    if (found.result.branchId && found.result.branchId !== actor.branchId)
      fail("Transaction belongs to a different branch.", 403);
    return found.result;
  }
  const result = await action();
  await db.query(
    "INSERT INTO transactions(organization_id,transaction_id,request_hash,result) VALUES($1,$2,$3,$4)",
    [actor.organizationId, transactionId, hash, JSON.stringify(result)],
  );
  return result;
}
