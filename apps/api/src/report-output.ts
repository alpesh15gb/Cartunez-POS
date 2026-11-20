import { createHash } from "node:crypto";
import { fail } from "./domain.js";
import type { report } from "./reports.js";

type Report = Awaited<ReturnType<typeof report>>;
const money = new Set([
  "gross", "returns", "coreReturns", "net", "discount", "tax", "cost", "margin", "value", "landedCost", "total", "openingCash",
  "cashSales", "cashRefunds", "cashIn", "cashOut", "netMovement", "expectedCash", "countedCash", "variance", "collected",
  "refunded", "charged", "outstanding", "revenue", "amount", "taxable", "unitPrice", "subtotal", "coreCharge", "coreDeposits",
  "rounding", "price", "retailPrice", "wholesalePrice", "cgst", "sgst", "igst", "utgst",
]);

function csv(rows: Record<string, unknown>[], currency: string) {
  const keys = [...new Set(rows.flatMap(Object.keys))];
  const header = (key: string) => money.has(key) ? key + " (" + currency + ")" : key === "taxRate" ? "taxRate (%)" : key;
  function convert(key: string, value: unknown): unknown {
    if (typeof value === "number" && (money.has(key) || key === "taxRate"))
      return (value / 100).toFixed(2);
    if (value instanceof Date) return value.toISOString();
    if (Array.isArray(value)) return value.map(entry => convert("", entry));
    if (value && typeof value === "object")
      return Object.fromEntries(Object.entries(value).map(([k, v]) => [header(k), convert(k, v)]));
    return value;
  }
  function quote(value: unknown, protect: boolean) {
    const raw = value == null ? "" : typeof value === "object" ? JSON.stringify(value) : String(value);
    const safe = protect && /^(?:\s*[=+@-]|[\t\r\n])/.test(raw) ? "'" + raw : raw;
    return '"' + safe.replace(/"/g, '""') + '"';
  }
  return [keys.map(key => quote(header(key), true)).join(","),
    ...rows.map(row => keys.map(key => quote(convert(key, row[key]), typeof row[key] === "string")).join(","))].join("\r\n");
}

export function reportOutput(result: Report, query: Record<string, string>) {
  const paged = query.page !== undefined || query.pageSize !== undefined;
  if (!paged && !query.format && !query.revision) return result;
  const revision = createHash("sha256").update(JSON.stringify([
    result.name, result.branchId, result.currency, result.rows, result.totals, result.pendingConflicts,
  ])).digest("hex");
  if (query.revision !== undefined && revision !== query.revision)
    fail("This report changed. Run the report again to see the latest figures.", 409);
  if (query.format === "csv" || query.format === "csv-json") {
    const content = csv(result.rows, result.currency);
    return query.format === "csv" ? content : {csv: content};
  }
  if (!paged) return result;
  const number = (value: string, max: number) => {
    if (!/^[1-9]\d*$/.test(value) || Number(value) > max) fail("Choose a valid report page and page size.");
    return Number(value);
  };
  const page = number(query.page ?? "1", Number.MAX_SAFE_INTEGER);
  const pageSize = number(query.pageSize ?? "25", 250);
  if (page > Math.max(1, Math.ceil(result.rows.length / pageSize))) fail("Report page is out of range.");
  const start = (page - 1) * pageSize;
  return {...result, page, pageSize, totalRows: result.rows.length, revision, rows: result.rows.slice(start, start + pageSize)};
}
