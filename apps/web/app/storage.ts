export type Json = Record<string, any>;
declare global {
  interface Window {
    motorlineNative?: {
      platform?: string;
      get(key: string): Promise<string | null>;
      set(key: string, value: string): Promise<void>;
      remove(key: string): Promise<void>;
      scan(): Promise<string | null>;
      print(): Promise<void>;
    };
  }
}
let database: Promise<IDBDatabase> | undefined;
async function db() {
  if (!database)
    database = new Promise((resolve, reject) => {
      const request = indexedDB.open("motorline-register", 1);
      request.onupgradeneeded = () =>
        request.result.createObjectStore("workspace");
      request.onerror = () => reject(request.error);
      request.onsuccess = () => resolve(request.result);
    });
  return database;
}
export async function initializeNative() {
  if (window.motorlineNative) return;
  await new Promise<void>((resolve) => {
    const script = document.createElement("script");
    script.src = "/native-client.js";
    script.onload = () => resolve();
    script.onerror = () => resolve();
    document.head.append(script);
  });
}
export async function readLocal<T>(key: string): Promise<T | null> {
  if (window.motorlineNative) {
    const value = await window.motorlineNative.get(key);
    return value ? JSON.parse(value) : null;
  }
  const database = await db();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction("workspace", "readonly");
    const request = transaction.objectStore("workspace").get(key);
    request.onsuccess = () => resolve(request.result ?? null);
    request.onerror = () => reject(request.error);
  });
}
export async function writeLocal(key: string, value: unknown) {
  if (window.motorlineNative)
    return window.motorlineNative.set(key, JSON.stringify(value));
  const database = await db();
  return new Promise<void>((resolve, reject) => {
    const transaction = database.transaction("workspace", "readwrite");
    transaction.objectStore("workspace").put(value, key);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}
export async function locked<T>(
  name: string,
  work: () => Promise<T>,
): Promise<T> {
  if (navigator.locks)
    return navigator.locks.request(`motorline:${name}`, work);
  return work();
}
export type Session = {
  token: string;
  user: Json;
  branchId: string;
  organizationId: string;
  expiresAt: string;
  api: string;
};
export type Workspace = {
  snapshot: Json;
  device: Json | null;
  nextInvoice: number;
  pending: Json[];
  lastSync: string;
  cart?: Json;
};
export const installationKey = (session: Session) =>
  new URL(session.api).href.replace(/\/$/, "");
export const scopeKey = (session: Session) =>
  `server:${installationKey(session)}:org:${session.organizationId}:branch:${session.branchId}:user:${session.user.id}`;
export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public detail: Json,
  ) {
    super(message);
  }
}
export async function request(
  session: Session,
  path: string,
  body?: unknown,
  method?: string,
): Promise<any> {
  let response: Response;
  try {
    response = await fetch(`${session.api}${path}`, {
      method: method || (body === undefined ? "GET" : "POST"),
      headers: {
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        Authorization: `Bearer ${session.token}`,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(12000),
    });
  } catch (reason) {
    const timedOut =
      reason instanceof DOMException && reason.name === "TimeoutError";
    throw new Error(
      timedOut
        ? "The server took too long to respond. Check the connection and try again."
        : `Cannot reach the server at ${session.api}. Check the address and network connection.`,
    );
  }
  const text = await response.text();
  let result;
  try {
    result = JSON.parse(text);
  } catch {
    result = { message: text };
  }
  if (!response.ok)
    throw new ApiError(
      result.message || result.error || "The request failed.",
      response.status,
      result,
    );
  return result;
}
export const emptyCart = () => ({
  transactionId: crypto.randomUUID(),
  lines: [] as Json[],
  tenders: [] as Json[],
  priceLevel: "retail",
  discount: 0,
  vehicle: null,
  customerId: "",
  shiftId: "",
});
export const normalize = (value: unknown) =>
  String(value ?? "")
    .replace(/[^a-z0-9]/gi, "")
    .toLowerCase();
export function fitment(
  product: Json,
  vehicle: Json | null,
): { status: string; missing: string[] } {
  if (product.universal) return { status: "universal", missing: [] };
  // No vehicle selected means no compatibility check is needed for the sale.
  if (!vehicle) return { status: "unchecked", missing: [] };
  const today = new Date().toISOString().slice(0, 10);
  const fits = (product.fitments || []).filter(
    (fit: Json) =>
      (!fit.effectiveFrom || fit.effectiveFrom <= today) &&
      (!fit.effectiveTo || fit.effectiveTo >= today),
  );
  if (!fits.length) return { status: "unverified", missing: [] };
  const candidates = fits.filter(
    (fit: Json) =>
      normalize(fit.make) === normalize(vehicle.make) &&
      normalize(fit.model) === normalize(vehicle.model) &&
      vehicle.year >= fit.yearFrom &&
      vehicle.year <= fit.yearTo,
  );
  const needed = new Set<string>();
  for (const candidate of candidates) {
    let valid = true;
    const ruleMissing = new Set<string>();
    for (const qualifier of [
      "engine",
      "fuel",
      "trim",
      "drivetrain",
      "market",
    ]) {
      if (candidate[qualifier] && !vehicle[qualifier]) {
        ruleMissing.add(qualifier);
        needed.add(qualifier);
      } else if (
        candidate[qualifier] &&
        normalize(candidate[qualifier]) !== normalize(vehicle[qualifier])
      )
        valid = false;
    }
    const excluded = (candidate.exclusions || []).some((exclusion: any) =>
      typeof exclusion === "string"
        ? Object.values(vehicle).some(
            (value) => normalize(value) === normalize(exclusion),
          )
        : Object.entries(exclusion).every(
            ([key, value]) => normalize(vehicle[key]) === normalize(value),
          ),
    );
    if (valid && !excluded && !ruleMissing.size)
      return { status: "compatible", missing: [] };
  }
  return {
    status: needed.size ? "unverified" : "incompatible",
    missing: [...needed],
  };
}
export function quote(cart: Json, products: Json[], roundingIncrement = 1, taxMode = "exclusive") {
  const amount = (value:number, label:string, max=100000000000) => {
    if (!Number.isSafeInteger(value) || value < 0 || value > max) throw new Error(`${label} exceeds the supported amount.`);
    return value;
  };
  if (!Number.isInteger(roundingIncrement) || roundingIncrement < 1 || roundingIncrement > 10000)
    throw new Error("Invalid rounding increment. Refresh the register settings.");
  const roundedRatio = (
    value: number,
    numerator: number,
    denominator: number,
  ) =>
    Number(
      (BigInt(value) * BigInt(numerator) +
        BigInt(Math.floor(denominator / 2))) /
        BigInt(denominator),
    );
  const entries = cart.lines.map((line: Json) => {
    const product = products.find((item) => item.id === line.productId);
    if (!product)
      throw new Error("A selected part is no longer in this branch catalog.");
    if (!Number.isInteger(line.qty) || line.qty < 1 || line.qty > 9999) throw new Error("Quantity must be a whole number between 1 and 9999.");
    amount(product.taxRate,"Tax rate",10000);
    amount(product.coreCharge || 0,"Core charge");
    amount(cart.priceLevel === "wholesale" ? product.wholesalePrice : product.retailPrice,"Unit price");
    return {
      ...line,
      product,
      unitPrice:
        cart.priceLevel === "wholesale"
          ? product.wholesalePrice
          : product.retailPrice,
    };
  });
  const subtotal = entries.reduce(
    (sum: number, line: Json) => amount(sum + amount(line.qty * line.unitPrice,"Line amount"),"Invoice subtotal"),
    0,
  );
  const discount = Math.min(Math.max(0, cart.discount || 0), subtotal);
  let allocation = 0;
  let running = 0;
  const lines = entries.map((line: Json) => {
    const amount = line.qty * line.unitPrice;
    running += amount;
    const cumulative = subtotal ? roundedRatio(discount, running, subtotal) : 0;
    const allocated = cumulative - allocation;
    allocation = cumulative;
    const gross = amount - allocated;
    const tax = taxMode === "inclusive"
      ? gross - roundedRatio(gross, 10000, 10000 + line.product.taxRate)
      : roundedRatio(gross, line.product.taxRate, 10000);
    const core = (line.product.coreCharge || 0) * line.qty;
    return {
      ...line,
      subtotal: amount,
      discount: allocated,
      tax,
      core,
      total: gross + (taxMode === "inclusive" ? 0 : tax) + core,
    };
  });
  const unrounded = lines.reduce(
    (sum: number, line: Json) => sum + line.total,
    0,
  );
  const total =
    roundedRatio(unrounded, 1, roundingIncrement) * roundingIncrement;
  amount(total,"Invoice total");
  return {
    lines,
    subtotal,
    discount,
    tax: lines.reduce((sum: number, line: Json) => sum + line.tax, 0),
    core: lines.reduce((sum: number, line: Json) => sum + line.core, 0),
    rounding: total - unrounded,
    total,
    taxMode,
  };
}
/** True when the final digit is a valid GS1 (EAN/UPC) check digit. */
export function gs1Valid(code: string) {
  if (!/^\d+$/.test(code)) return false;
  const digits = code.split("").map(Number);
  const check = digits.pop()!;
  const sum = digits
    .reverse()
    .reduce((total, digit, index) => total + digit * (index % 2 === 0 ? 3 : 1), 0);
  return (10 - (sum % 10)) % 10 === check;
}
/** Pick the symbology printed on packaging when the code is a valid retail number. */
export function barcodeFormat(code: string) {
  if (code.length === 13 && gs1Valid(code)) return "EAN13";
  if (code.length === 12 && gs1Valid(code)) return "UPC";
  if (code.length === 8 && gs1Valid(code)) return "EAN8";
  return "CODE128";
}
/** Create an in-store EAN-13 (GS1 prefix 2 is reserved for internal use). */
export function inStoreBarcode(taken: Set<string>) {
  for (;;) {
    let body = "2";
    for (let index = 0; index < 11; index++)
      body += Math.floor(Math.random() * 10);
    const sum = body
      .split("")
      .map(Number)
      .reverse()
      .reduce((total, digit, index) => total + digit * (index % 2 === 0 ? 3 : 1), 0);
    const code = body + ((10 - (sum % 10)) % 10);
    if (!taken.has(code)) return code;
  }
}
