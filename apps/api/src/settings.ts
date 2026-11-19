import { fail, text, multiline, roundRatio } from "./domain.js";

export function currencyCode(value: unknown): string {
  const currency = text(value, "currency", true, 3).toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency))
    fail("Enter a three-letter ISO currency code.");
  try {
    if (!Intl.supportedValuesOf("currency").includes(currency))
      fail("Choose a supported ISO currency.");
    if (
      new Intl.NumberFormat("en", {
        style: "currency",
        currency,
      }).resolvedOptions().maximumFractionDigits !== 2
    )
      fail(
        "This register supports currencies with two minor-unit decimal places.",
      );
  } catch (error: any) {
    if (error.statusCode) throw error;
    fail("Choose a supported currency with two decimal places.");
  }
  return currency;
}
export function emailAddress(value: unknown, required = true) {
  const email = text(value, "email", required, 254).toLowerCase();
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
    fail("Enter a valid email address.");
  return email;
}
export function businessProfile(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    fail("Business profile must be an object.");
  const input = value as Record<string, unknown>;
  const result: Record<string, string> = {};
  for (const key of [
    "legalName",
    "tradingName",
    "address",
    "taxRegistrationId",
    "phone",
    "email",
    "stateCode",
  ]) {
    if (input[key] !== undefined)
      result[key] =
        key === "email"
          ? emailAddress(input[key], false)
          : key === "address"
            ? multiline(input[key], "address")
            : text(input[key], key, false, 200);
  }
  return result;
}
export function invoiceProfile(
  settings: Record<string, any>,
  branch: Record<string, any>,
) {
  return {
    business: settings.business || {},
    branch: {
      id: branch.id,
      name: branch.name,
      address: branch.address || "",
      stateCode: branch.stateCode || "",
    },
    currency: settings.currency,
    taxDisplayName: settings.taxDisplayName || "Tax",
    taxMode: settings.taxMode || "exclusive",
    taxScheme: settings.taxScheme || "general",
    localTaxName: settings.localTaxName || "SGST",
    receiptFooter: settings.receiptFooter || "",
  };
}

export function gstState(value: unknown, label = "state code") {
  const code = text(value, label, true, 2);
  if (!/^(0[1-9]|[12][0-9]|3[0-8])$/.test(code))
    fail(`Enter a two-digit domestic GST ${label}.`);
  return code;
}
export function gstRegistration(
  value: unknown,
  state: string,
  label = "GSTIN",
) {
  const registration = text(value, label, true, 15).toUpperCase();
  if (
    !/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(registration) ||
    !registration.startsWith(state)
  )
    fail(`Enter a valid ${label} matching the state code.`);
  return registration;
}
export function gstProfile(profile: ReturnType<typeof invoiceProfile>) {
  if (profile.taxScheme !== "india-gst") return;
  if (profile.currency !== "INR")
    fail("India GST mode requires INR as the accounting currency.");
  const state = gstState(profile.business.stateCode, "business state code");
  gstRegistration(profile.business.taxRegistrationId, state, "business GSTIN");
  if (!profile.business.legalName || !profile.business.address)
    fail("Enter the registered business legal name and address for India GST.");
  if (profile.branch.stateCode && profile.branch.stateCode !== state)
    fail(
      "This organization supports one GST registration state. Use a separate organization for another GST registration.",
    );
}
export function documentNumber(value: string, scheme: string) {
  if (scheme === "india-gst" && !/^[A-Za-z0-9/-]{1,16}$/.test(value))
    fail(
      "GST invoice and credit-note numbers must be at most 16 letters, numbers, hyphens, or slashes. Shorten the prefix or branch code.",
    );
  return value;
}
export type TaxComponent = { name: string; rate: number; amount: number };
export function splitTax(
  tax: number,
  rate: number,
  profile: ReturnType<typeof invoiceProfile>,
  placeOfSupply: string,
): TaxComponent[] {
  if (profile.taxScheme !== "india-gst") return [];
  if (profile.business.stateCode !== placeOfSupply)
    return [{ name: "IGST", rate, amount: tax }];
  const central = roundRatio(tax, 1, 2);
  return [
    { name: "CGST", rate: rate / 2, amount: central },
    { name: profile.localTaxName, rate: rate / 2, amount: tax - central },
  ];
}
export function taxTotals(lines: { taxComponents?: TaxComponent[] }[]) {
  const totals = new Map<string, number>();
  for (const line of lines)
    for (const component of line.taxComponents || [])
      totals.set(
        component.name,
        (totals.get(component.name) || 0) + component.amount,
      );
  return [...totals].map(([name, amount]) => ({ name, amount }));
}

/** Shop barcode label design (what prints on each label). */
export function labelLayout(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    fail("Choose what to print on the label.");
  const input = value as Record<string, unknown>;
  const allowed = new Set([
    "widthMm", "heightMm", "columns", "gapMm", "shopName", "name", "brand",
    "partNumber", "sku", "bin", "digits", "price", "nameSize", "priceSize", "extra",
  ]);
  for (const key of Object.keys(input))
    if (!allowed.has(key)) fail(`Unknown label setting ${key}.`);
  const number = (key: string, min: number, max: number, fallback: number) => {
    const raw = input[key] ?? fallback;
    if (typeof raw !== "number" || !Number.isFinite(raw) || raw < min || raw > max)
      fail(`Label ${key} must be between ${min} and ${max}.`);
    return Math.round((raw as number) * 10) / 10;
  };
  const flag = (key: string, fallback: boolean) => {
    const raw = input[key] ?? fallback;
    if (typeof raw !== "boolean") fail(`Label ${key} must be on or off.`);
    return raw as boolean;
  };
  const choice = (key: string, options: string[], fallback: string) => {
    const raw = input[key] ?? fallback;
    if (typeof raw !== "string" || !options.includes(raw))
      fail(`Label ${key} must be one of ${options.join(", ")}.`);
    return raw as string;
  };
  const columns = number("columns", 1, 3, 1);
  if (!Number.isInteger(columns)) fail("Labels across the roll must be 1, 2 or 3.");
  return {
    widthMm: number("widthMm", 20, 110, 50),
    heightMm: number("heightMm", 10, 150, 25),
    columns,
    gapMm: number("gapMm", 0, 10, 2),
    shopName: flag("shopName", false),
    name: flag("name", true),
    brand: flag("brand", false),
    partNumber: flag("partNumber", false),
    sku: flag("sku", true),
    bin: flag("bin", false),
    digits: flag("digits", true),
    price: choice("price", ["price", "mrp", "both", "none"], "price"),
    nameSize: choice("nameSize", ["small", "medium", "large"], "medium"),
    priceSize: choice("priceSize", ["small", "medium", "large"], "medium"),
    extra: text(input.extra ?? "", "label extra text", false, 60),
  };
}
