import { parse } from "csv-parse/sync";
import { randomInt } from "node:crypto";
import { id, integer, fail, text, normalize, barcodeKey } from "./domain.js";
import type { RecordData } from "./db.js";

export function buildProduct(value: RecordData, productId = id("part")) {
  const product: any = { id: productId };
  // Only the name is required. A blank SKU gets an item code (CT-12345678);
  // brand, category and unit may be filled in later.
  product.name = text(value.name ?? "", "name");
  for (const key of ["sku", "brand", "partNumber", "category", "unit"])
    product[key] = text(value[key] ?? "", key, false);
  if (!product.sku) product.sku = `CT-${randomInt(10000000, 100000000)}`;
  if (!product.unit) product.unit = "Each";
  if (!product.category) product.category = "General";
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
    // Blank (for example an unknown purchase price) counts as zero.
    product[key] = integer(value[key] === "" || value[key] == null ? 0 : value[key], key);
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
  return product;
}

/** Active and removed SKU and barcode identities share the same catalog namespace. */
export class CatalogCodes {
  private skus = new Map<string, string>();
  private barcodes = new Map<string, string>();
  private normalizedBarcodes = new Map<string, string>();
  /** Name + brand, to stop a CSV without SKUs from adding the same parts twice. */
  readonly names = new Map<string, string>();

  constructor(products: RecordData[]) {
    for (const product of products) this.add(product);
  }

  add(product: RecordData) {
    this.skus.set(normalize(product.sku), product.name);
    this.names.set(normalize(`${product.name}|${product.brand || ""}`), product.sku);
    for (const code of product.barcodes || []) {
      this.barcodes.set(barcodeKey(code), product.name);
      this.normalizedBarcodes.set(normalize(code), product.name);
    }
  }

  check(product: RecordData, previous?: RecordData) {
    const sku = normalize(product.sku);
    let conflict = this.skus.get(sku);
    if (sku !== normalize(previous?.sku)) conflict ??= this.normalizedBarcodes.get(sku);
    const oldCodes = new Set((previous?.barcodes || []).map(barcodeKey));
    for (const code of product.barcodes) {
      if (oldCodes.has(barcodeKey(code))) continue;
      conflict ??= this.barcodes.get(barcodeKey(code)) ?? this.skus.get(normalize(code));
    }
    if (conflict) fail(`SKU or barcode conflicts with ${conflict}.`, 409);
  }
}

const required = ["name", "retailPrice"];
const optional = ["sku", "brand", "category", "unit", "cost", "taxPercent", "barcodes", "wholesalePrice", "hsnSac", "partNumber", "reorderLevel", "serialTracked", "universal", "type"];
const headerNames = new Map([...required, ...optional].map((name) => [name.toLowerCase(), name]));

function hundredths(value: string, label: string) {
  if (!/^\d+(\.\d{1,2})?$/.test(value)) fail(`Enter a nonnegative ${label} with up to two decimal places.`);
  const [units, fraction = ""] = value.split(".");
  return Number(units + fraction.padEnd(2, "0"));
}

function flag(value: string | undefined, label: string) {
  if (!value || /^(false|no)$/i.test(value)) return false;
  if (/^(true|yes)$/i.test(value)) return true;
  fail(`Use yes or no for ${label}.`);
}

export function previewCatalog(csv: unknown, codes: CatalogCodes, gst: boolean) {
  if (typeof csv !== "string" || Buffer.byteLength(csv, "utf8") > 512 * 1024) fail("Choose a UTF-8 CSV up to 512 KiB.");
  let table: string[][];
  try {
    table = parse(csv, { bom: true, trim: true, skip_empty_lines: true, max_record_size: 32768 });
  } catch (error: any) {
    fail(`Invalid CSV${error.lines ? " near line " + error.lines : ""}. Check quotes and column counts.`);
  }
  if (table.length < 2 || table.length > 1001) fail("Include a header and 1 to 1,000 parts per file.");
  const seen = new Set<string>();
  const headers = table[0].map((cell) => {
    const key = headerNames.get(cell.trim().toLowerCase());
    if (!key) fail(`Unknown column "${cell.slice(0, 80)}". Use the catalog template.`);
    if (seen.has(key)) fail(`Duplicate column "${key}".`);
    seen.add(key);
    return key;
  });
  const missing = required.filter((name) => !seen.has(name));
  if (missing.length) fail(`Missing columns: ${missing.join(", ")}.`);
  const rows: { row: number; sku: string; name: string; retailPrice?: number; error?: string }[] = [];
  const products: RecordData[] = [];
  for (const [index, cells] of table.slice(1).entries()) {
    const input = Object.fromEntries(headers.map((key, i) => [key, cells[i].trim()]));
    const row = { row: index + 2, sku: input.sku, name: input.name };
    try {
      if (input.type && !["part", "service"].includes(input.type)) fail("Type must be part or service.");
      if ((gst || input.hsnSac) && !/^(\d{4}|\d{6}|\d{8})$/.test(input.hsnSac || "")) fail("Enter a 4, 6 or 8 digit HSN/SAC.");
      const barcodes = input.barcodes ? input.barcodes.split("|").map((code) => code.trim()) : [];
      if (new Set(barcodes.map(barcodeKey)).size !== barcodes.length) fail("Duplicate barcode in this row.");
      for (const code of barcodes) {
        if (/^\d{13}$/.test(code) && barcodeKey(code).length !== 14) fail("Invalid EAN-13 check digit.");
      }
      if (!input.sku) {
        const existing = codes.names.get(normalize(`${input.name}|${input.brand || ""}`));
        if (existing) fail(`${input.name} already exists (SKU ${existing}). Add a sku column to update parts, or remove this row.`, 409);
      }
      const product = buildProduct({
        ...input, barcodes, cost: input.cost ? hundredths(input.cost, "cost") : 0, retailPrice: hundredths(input.retailPrice, "retail price"),
        wholesalePrice: hundredths(input.wholesalePrice || input.retailPrice, "wholesale price"),
        taxRate: input.taxPercent ? hundredths(input.taxPercent, "tax rate") : undefined, reorderLevel: input.reorderLevel || 0,
        serialTracked: flag(input.serialTracked, "serial tracking"), universal: flag(input.universal, "universal fit"),
      });
      if (product.type === "service" && product.serialTracked) fail("A service cannot track serial numbers.");
      codes.check(product);
      codes.add(product);
      products.push(product);
      rows.push({ ...row, sku: product.sku, retailPrice: product.retailPrice });
    } catch (error: any) {
      if (![400, 409].includes(error.statusCode)) throw error;
      rows.push({ ...row, error: error.message });
    }
  }
  return { rows, products, valid: products.length === rows.length };
}
