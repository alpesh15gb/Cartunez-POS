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
export async function inventory(db: Database, actor: Actor) {
  const holds = await records(db, actor.organizationId, "hold", actor.branchId);
  const rows = (
    await db.query(
      "SELECT product_id,bin_id,quantity FROM stock WHERE organization_id=$1 AND branch_id=$2",
      [actor.organizationId, actor.branchId],
    )
  ).rows;
  // Units held for open Magento orders, taken from the fullest sellable bins first.
  const online = new Map<string, number>();
  for (const order of await records(db, actor.organizationId, "onlineOrder", actor.branchId))
    for (const line of order.lines || [])
      if (line.productId)
        online.set(line.productId, (online.get(line.productId) || 0) + Number(line.reserved || 0) + Number(line.awaiting || 0));
  const sellable = new Set(
    (await records(db, actor.organizationId, "location", actor.branchId)).filter((b) => b.kind === "sellable").map((b) => b.id),
  );
  const onlineByBin = new Map<string, number>();
  for (const [productId, units] of online) {
    let left = units;
    for (const row of rows
      .filter((r) => r.product_id === productId && sellable.has(r.bin_id))
      .sort((a, b) => Number(b.quantity) - Number(a.quantity))) {
      if (left <= 0) break;
      const take = Math.min(left, Math.max(0, Number(row.quantity)));
      onlineByBin.set(productId + "|" + row.bin_id, take);
      left -= take;
    }
  }
  return rows.map((row) => {
    const reserved = (onlineByBin.get(row.product_id + "|" + row.bin_id) || 0) + holds.reduce(
      (sum, hold) =>
        sum +
        (hold.cart.lines || [])
          .filter(
            (line: any) =>
              line.productId === row.product_id && line.binId === row.bin_id,
          )
          .reduce((sum: number, line: any) => sum + line.qty, 0),
      0,
    );
    return {
      productId: row.product_id,
      binId: row.bin_id,
      quantity: Number(row.quantity),
      reserved,
      available: Number(row.quantity) - reserved,
    };
  });
}
export function fitment(
  product: RecordData,
  vehicle?: RecordData,
  effectiveDate = now().slice(0, 10),
) {
  if (product.universal) return { status: "universal", missing: [] };
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
) {
  if (["owner", "manager"].includes(actor.role)) return;
  if (!approvalId) fail(`Manager approval is required for ${action}.`, 403);
  const approval = await scoped(db, actor, "approval", approvalId);
  if (
    approval.action !== action ||
    approval.transactionId !== transactionId ||
    approval.used ||
    new Date(approval.expiresAt).getTime() < Date.now()
  )
    fail("Approval is invalid or expired.", 403);
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
