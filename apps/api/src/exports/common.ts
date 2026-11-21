// WS-F: shared helpers for accounting exports (GSTR-1, Tally).
import type { Database } from "../db.js";
import { getRecord, records } from "../db.js";
import { type Actor, allow, fail } from "../domain.js";

export function validDay(value: unknown, label: string) {
  const time = new Date(`${value}T00:00:00Z`);
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) ||
      !Number.isFinite(time.getTime()) || time.toISOString().slice(0, 10) !== value)
    fail(`Choose the ${label} as a date (YYYY-MM-DD).`);
  return value as string;
}

/** The documents of an export period, read the same way the reports read them. */
export async function exportPeriod(db: Database, actor: Actor, query: any) {
  allow(actor, ["owner", "manager"]);
  const dateFrom = validDay(query.dateFrom, "start date");
  const dateTo = validDay(query.dateTo, "end date");
  if (dateFrom > dateTo) fail("The start date must be on or before the end date.");
  const settings = (await getRecord(db, actor.organizationId, "settings", "settings")) || {};
  const timeZone = settings.currency === "INR" ? "Asia/Kolkata" : "UTC";
  const formatter = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
  const businessDay = (date: string) => formatter.format(new Date(date));
  // One GST registration covers every branch, so the owner can export all of them.
  const allBranches = query.branches === "all";
  if (allBranches && actor.role !== "owner") fail("Only the owner can export every branch together.", 403);
  const branch = allBranches ? undefined : actor.branchId;
  const inPeriod = (date: string) => { const day = businessDay(date); return day >= dateFrom && day <= dateTo; };
  return { settings, timeZone, businessDay, dateFrom, dateTo, branch, allBranches, inPeriod,
    load: async (kind: string) => (await records(db, actor.organizationId, kind, branch)) };
}

/** Paise to rupees as a number with two decimals (what the GST portal and Tally expect). */
export const rupees = (paise: number) => Math.round(paise) / 100;
export const rupeeText = (paise: number) => {
  const sign = paise < 0 ? "-" : "";
  const abs = Math.abs(Math.round(paise));
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, "0")}`;
};

export function csvText(header: string[], rows: unknown[][]) {
  const quote = (value: unknown) => {
    const raw = value == null ? "" : String(value);
    const safe = typeof value === "string" && /^(?:\s*[=+@-]|[\t\r\n])/.test(raw) ? "'" + raw : raw;
    return '"' + safe.replace(/"/g, '""') + '"';
  };
  return [header.map(quote).join(","), ...rows.map((row) => row.map(quote).join(","))].join("\r\n");
}

/** Taxable value of a sale or credit-note line (same rule as the tax report). */
export const taxableOf = (line: any) => line.subtotal - line.discount - (line.taxMode === "inclusive" ? line.tax : 0);

/** CGST / SGST (or UTGST) / IGST amounts of a line. */
export function splitOf(line: any) {
  const out = { igst: 0, cgst: 0, sgst: 0 };
  for (const c of line.taxComponents || []) {
    if (c.name === "IGST") out.igst += c.amount;
    else if (c.name === "CGST") out.cgst += c.amount;
    else if (c.name === "SGST" || c.name === "UTGST") out.sgst += c.amount;
  }
  return out;
}
