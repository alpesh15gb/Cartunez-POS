// WS-F: GSTR-1 from the shop's GST invoices and credit notes.
//
// Output:
//  * `portal`: JSON in the GST offline tool / portal upload shape
//    (gstin, fp, b2b, b2cl, b2cs, cdnr, cdnur, hsn{hsn_b2b, hsn_b2c}).
//  * CSV per section with the column headings of the offline tool's Excel
//    template, so each can be pasted into the template.
// No e-invoice / IRN (owner decision). Amounts are rupees with two decimals.
//
// Rules used:
//  * B2B   : invoice to a customer with a GSTIN.
//  * B2CL  : unregistered, inter-state, invoice value above Rs 1,00,000.
//  * B2CS  : every other unregistered invoice, summed by place of supply and rate.
//  * CDNR  : credit notes on invoices to registered customers.
//  * CDNUR : credit notes on B2CL invoices; other unregistered credit notes
//            reduce B2CS (how the portal expects small B2C returns).
//  * HSN   : by HSN/SAC and rate, split B2B / B2C (Table 12 since 2025).
import type { Database } from "../db.js";
import { type Actor, fail } from "../domain.js";
import { csvText, exportPeriod, rupees, splitOf, taxableOf } from "./common.js";
import type { Sheet } from "./xlsx.js";

export const B2CL_LIMIT = 100000_00;

export const GST_STATES: Record<string, string> = {
  "01": "Jammu and Kashmir", "02": "Himachal Pradesh", "03": "Punjab", "04": "Chandigarh", "05": "Uttarakhand",
  "06": "Haryana", "07": "Delhi", "08": "Rajasthan", "09": "Uttar Pradesh", "10": "Bihar", "11": "Sikkim",
  "12": "Arunachal Pradesh", "13": "Nagaland", "14": "Manipur", "15": "Mizoram", "16": "Tripura", "17": "Meghalaya",
  "18": "Assam", "19": "West Bengal", "20": "Jharkhand", "21": "Odisha", "22": "Chhattisgarh", "23": "Madhya Pradesh",
  "24": "Gujarat", "25": "Daman and Diu", "26": "Dadra and Nagar Haveli and Daman and Diu", "27": "Maharashtra",
  "28": "Andhra Pradesh (Old)", "29": "Karnataka", "30": "Goa", "31": "Lakshadweep", "32": "Kerala", "33": "Tamil Nadu",
  "34": "Puducherry", "35": "Andaman and Nicobar Islands", "36": "Telangana", "37": "Andhra Pradesh", "38": "Ladakh",
  "97": "Other Territory",
};

/** Unit quantity codes the portal accepts, from the shop's unit names. */
const UQC: Record<string, string> = {
  each: "NOS", piece: "PCS", pieces: "PCS", pcs: "PCS", pc: "PCS", nos: "NOS", no: "NOS", number: "NOS", unit: "UNT", units: "UNT",
  litre: "LTR", liter: "LTR", l: "LTR", ltr: "LTR", ml: "MLT", kg: "KGS", kgs: "KGS", g: "GMS", gm: "GMS", gram: "GMS",
  set: "SET", sets: "SET", pair: "PRS", pairs: "PRS", box: "BOX", metre: "MTR", meter: "MTR", m: "MTR", roll: "ROL",
  can: "CAN", bottle: "BTL", pack: "PAC", packet: "PAC", kit: "SET", dozen: "DOZ",
};
const UQC_NAMES: Record<string, string> = {
  NOS: "NUMBERS", PCS: "PIECES", UNT: "UNITS", LTR: "LITRES", MLT: "MILILITRE", KGS: "KILOGRAMS", GMS: "GRAMMES",
  SET: "SETS", PRS: "PAIRS", BOX: "BOX", MTR: "METERS", ROL: "ROLLS", CAN: "CANS", BTL: "BOTTLES", PAC: "PACKS",
  DOZ: "DOZENS", OTH: "OTHERS", NA: "NA",
};
export function uqc(unit: string, hsn: string) {
  if (hsn.startsWith("99")) return "NA"; // services (SAC) have no quantity
  return UQC[String(unit || "").trim().toLowerCase()] || "OTH";
}

type Amounts = { txval: number; iamt: number; camt: number; samt: number };
const zero = (): Amounts => ({ txval: 0, iamt: 0, camt: 0, samt: 0 });
function addLine(target: Amounts, line: any, sign = 1) {
  const split = splitOf(line);
  target.txval += sign * taxableOf(line);
  target.iamt += sign * split.igst;
  target.camt += sign * split.cgst;
  target.samt += sign * split.sgst;
}
const rateOf = (line: any) => Number(line.taxRate || 0) / 100;
const money = (a: Amounts) => ({ txval: rupees(a.txval), iamt: rupees(a.iamt), camt: rupees(a.camt), samt: rupees(a.samt), csamt: 0 });

/** dd-mm-yyyy (JSON) and dd-Mon-yyyy (offline tool template). */
const dmy = (day: string) => `${day.slice(8, 10)}-${day.slice(5, 7)}-${day.slice(0, 4)}`;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const dMonY = (day: string) => `${day.slice(8, 10)}-${MONTHS[Number(day.slice(5, 7)) - 1]}-${day.slice(0, 4)}`;
const posName = (code: string) => `${code}-${GST_STATES[code] || "Unknown"}`;

function byRate(lines: any[], sign = 1) {
  const rates = new Map<number, Amounts>();
  for (const line of lines) {
    const rate = rateOf(line);
    if (!rates.has(rate)) rates.set(rate, zero());
    addLine(rates.get(rate)!, line, sign);
  }
  return [...rates.entries()].sort((a, b) => a[0] - b[0]);
}

export async function gstr1(db: Database, actor: Actor, query: any) {
  const period = await exportPeriod(db, actor, query);
  const { settings, businessDay } = period;
  if (settings.taxScheme === "none")
    fail("This shop is not GST registered, so there is no GSTR-1 to file. Bills carry no GST.", 409);
  if (settings.taxScheme !== "india-gst")
    fail("GSTR-1 needs India GST turned on in Settings (tax scheme, GSTIN and state).", 409);
  const business = settings.business || {};
  const gstin = String(business.taxRegistrationId || "");
  const home = String(business.stateCode || "");
  if (!gstin || !home) fail("Enter the shop's GSTIN and state code in Settings before exporting GSTR-1.", 409);

  const allInvoices = await period.load("invoice");
  const invoicesById = new Map(allInvoices.map((i) => [i.id, i]));
  const invoices = allInvoices.filter((i) => period.inPeriod(i.createdAt));
  const credits = (await period.load("return")).filter((r) => period.inPeriod(r.createdAt));
  const registered = (doc: any) => String(doc.customer?.taxRegistrationId || "").trim().toUpperCase();
  const posOf = (doc: any) => String(doc.placeOfSupply || home);
  const isB2cl = (invoice: any) => !registered(invoice) && posOf(invoice) !== home && Number(invoice.total) > B2CL_LIMIT;

  // ---- B2B, B2CL, B2CS ----
  const b2b = new Map<string, any[]>();
  const b2bRows: unknown[][] = [];
  const b2cl = new Map<string, any[]>();
  const b2clRows: unknown[][] = [];
  const b2cs = new Map<string, { pos: string; rt: number; amounts: Amounts }>();
  const b2csAdd = (doc: any, lines: any[], sign: number) => {
    for (const [rt, amounts] of byRate(lines, sign)) {
      const key = posOf(doc) + "|" + rt;
      const row = b2cs.get(key) ?? { pos: posOf(doc), rt, amounts: zero() };
      for (const k of ["txval", "iamt", "camt", "samt"] as const) row.amounts[k] += amounts[k];
      b2cs.set(key, row);
    }
  };
  const hsn = { b2b: new Map<string, any>(), b2c: new Map<string, any>() };
  const hsnAdd = (table: Map<string, any>, line: any, quantity: number, sign: number) => {
    const code = String(line.hsnSac || "").trim() || "NA";
    const rt = rateOf(line);
    const key = code + "|" + rt;
    const row = table.get(key) ?? { hsn_sc: code, desc: String(line.name || "").slice(0, 30), uqc: uqc(line.unit, code), qty: 0, rt, amounts: zero() };
    row.qty += row.uqc === "NA" ? 0 : sign * quantity;
    addLine(row.amounts, line, sign);
    table.set(key, row);
  };

  for (const invoice of invoices) {
    const ctin = registered(invoice);
    const day = businessDay(invoice.createdAt);
    const pos = posOf(invoice);
    const itms = byRate(invoice.lines).map(([rt, a], i) => ({ num: i + 1, itm_det: { rt, ...money(a) } }));
    if (ctin) {
      const list = b2b.get(ctin) ?? [];
      list.push({ inum: invoice.number, idt: dmy(day), val: rupees(invoice.total), pos, rchrg: "N", inv_typ: "R", itms });
      b2b.set(ctin, list);
      for (const [rt, a] of byRate(invoice.lines))
        b2bRows.push([ctin, invoice.customer?.name || "", invoice.number, dMonY(day), rupees(invoice.total), posName(pos), "N", "",
          "Regular B2B", "", rt, rupees(a.txval), 0]);
    } else if (isB2cl(invoice)) {
      const list = b2cl.get(pos) ?? [];
      list.push({ inum: invoice.number, idt: dmy(day), val: rupees(invoice.total), itms });
      b2cl.set(pos, list);
      for (const [rt, a] of byRate(invoice.lines))
        b2clRows.push([invoice.number, dMonY(day), rupees(invoice.total), posName(pos), "", rt, rupees(a.txval), 0, ""]);
    } else b2csAdd(invoice, invoice.lines, 1);
    for (const line of invoice.lines) hsnAdd(ctin ? hsn.b2b : hsn.b2c, line, line.qty, 1);
  }

  // ---- Credit notes ----
  const cdnr = new Map<string, any[]>();
  const cdnrRows: unknown[][] = [];
  const cdnur: any[] = [];
  const cdnurRows: unknown[][] = [];
  for (const credit of credits) {
    const original = invoicesById.get(credit.invoiceId) || {};
    const doc = { ...original, customer: credit.customer ?? original.customer, placeOfSupply: credit.placeOfSupply || original.placeOfSupply };
    const ctin = registered(doc);
    const day = businessDay(credit.createdAt);
    const pos = posOf(doc);
    const value = credit.lines.reduce((n: number, l: any) => n + l.total, 0);
    const itms = byRate(credit.lines).map(([rt, a], i) => ({ num: i + 1, itm_det: { rt, ...money(a) } }));
    if (ctin) {
      const list = cdnr.get(ctin) ?? [];
      list.push({ ntty: "C", nt_num: credit.number, nt_dt: dmy(day), val: rupees(value), pos, rchrg: "N", inv_typ: "R", itms });
      cdnr.set(ctin, list);
      for (const [rt, a] of byRate(credit.lines))
        cdnrRows.push([ctin, doc.customer?.name || "", credit.number, dMonY(day), "C", posName(pos), "N", "Regular B2B",
          rupees(value), "", rt, rupees(a.txval), 0]);
    } else if (original.id && isB2cl(original)) {
      cdnur.push({ typ: "B2CL", ntty: "C", nt_num: credit.number, nt_dt: dmy(day), val: rupees(value), pos, itms });
      for (const [rt, a] of byRate(credit.lines))
        cdnurRows.push(["B2CL", credit.number, dMonY(day), "C", posName(pos), rupees(value), "", rt, rupees(a.txval), 0]);
    } else b2csAdd(doc, credit.lines, -1);
    for (const line of credit.lines) hsnAdd(ctin ? hsn.b2b : hsn.b2c, line, line.quantity, -1);
  }

  const b2csList = [...b2cs.values()].filter((r) => r.amounts.txval || r.amounts.iamt || r.amounts.camt || r.amounts.samt)
    .sort((a, b) => a.pos.localeCompare(b.pos) || a.rt - b.rt)
    .map((r) => ({ sply_ty: r.pos === home ? "INTRA" : "INTER", pos: r.pos, typ: "OE", rt: r.rt, ...money(r.amounts) }));
  const hsnList = (table: Map<string, any>) => [...table.values()]
    .sort((a, b) => a.hsn_sc.localeCompare(b.hsn_sc) || a.rt - b.rt)
    .map((r, i) => ({ num: i + 1, hsn_sc: r.hsn_sc, desc: r.desc, uqc: r.uqc, qty: r.qty, rt: r.rt,
      ...money(r.amounts) }));
  const fp = period.dateTo.slice(5, 7) + period.dateTo.slice(0, 4);
  const portal = {
    gstin,
    fp,
    version: "GST3.1.6",
    hash: "hash",
    b2b: [...b2b.entries()].map(([ctin, inv]) => ({ ctin, inv })),
    b2cl: [...b2cl.entries()].map(([pos, inv]) => ({ pos, inv })),
    b2cs: b2csList,
    cdnr: [...cdnr.entries()].map(([ctin, nt]) => ({ ctin, nt })),
    cdnur,
    hsn: { hsn_b2b: hsnList(hsn.b2b), hsn_b2c: hsnList(hsn.b2c) },
  };
  // Drop empty sections: the portal rejects empty arrays in some sections.
  for (const key of ["b2b", "b2cl", "b2cs", "cdnr", "cdnur"] as const)
    if (!(portal as any)[key].length) delete (portal as any)[key];

  // ---- Summary that reconciles with the tax report ----
  const total = zero();
  for (const invoice of invoices) for (const line of invoice.lines) addLine(total, line, 1);
  for (const credit of credits) for (const line of credit.lines) addLine(total, line, -1);
  const summary = {
    gstin, period: fp, dateFrom: period.dateFrom, dateTo: period.dateTo,
    invoices: invoices.length, creditNotes: credits.length,
    b2bInvoices: [...b2b.values()].reduce((n, l) => n + l.length, 0),
    b2clInvoices: [...b2cl.values()].reduce((n, l) => n + l.length, 0),
    // Net figures in paise, comparable with the tax report's totals.
    taxable: total.txval, igst: total.iamt, cgst: total.camt, sgst: total.samt, tax: total.iamt + total.camt + total.samt,
    multipleMonths: period.dateFrom.slice(0, 7) !== period.dateTo.slice(0, 7),
  };

  const hsnHeader = ["HSN", "Description", "UQC", "Total Quantity", "Total Value", "Rate", "Taxable Value",
    "Integrated Tax Amount", "Central Tax Amount", "State/UT Tax Amount", "Cess Amount"];
  const hsnRows = (list: any[]) => list.map((r) => [r.hsn_sc, r.desc, `${r.uqc}-${UQC_NAMES[r.uqc] || "OTHERS"}`, r.qty,
    Math.round((r.txval + r.iamt + r.camt + r.samt) * 100) / 100, r.rt, r.txval, r.iamt, r.camt, r.samt, 0]);
  const sections: Record<string, { header: string[]; rows: unknown[][] }> = {
    b2b: { header: ["GSTIN/UIN of Recipient", "Receiver Name", "Invoice Number", "Invoice date", "Invoice Value", "Place Of Supply",
      "Reverse Charge", "Applicable % of Tax Rate", "Invoice Type", "E-Commerce GSTIN", "Rate", "Taxable Value", "Cess Amount"], rows: b2bRows },
    b2cl: { header: ["Invoice Number", "Invoice date", "Invoice Value", "Place Of Supply", "Applicable % of Tax Rate", "Rate",
      "Taxable Value", "Cess Amount", "E-Commerce GSTIN"], rows: b2clRows },
    b2cs: { header: ["Type", "Place Of Supply", "Applicable % of Tax Rate", "Rate", "Taxable Value", "Cess Amount", "E-Commerce GSTIN"],
      rows: b2csList.map((r) => ["OE", posName(r.pos), "", r.rt, r.txval, 0, ""]) },
    cdnr: { header: ["GSTIN/UIN of Recipient", "Receiver Name", "Note Number", "Note Date", "Note Type", "Place Of Supply",
      "Reverse Charge", "Note Supply Type", "Note Value", "Applicable % of Tax Rate", "Rate", "Taxable Value", "Cess Amount"], rows: cdnrRows },
    cdnur: { header: ["UR Type", "Note Number", "Note Date", "Note Type", "Place Of Supply", "Note Value", "Applicable % of Tax Rate",
      "Rate", "Taxable Value", "Cess Amount"], rows: cdnurRows },
    "hsn-b2b": { header: hsnHeader, rows: hsnRows(portal.hsn.hsn_b2b) },
    "hsn-b2c": { header: hsnHeader, rows: hsnRows(portal.hsn.hsn_b2c) },
  };
  return { portal, summary, sections };
}

export type Gstr1 = Awaited<ReturnType<typeof gstr1>>;

export function gstr1Csv(result: Gstr1, section: string) {
  const table = result.sections[section];
  if (!table) fail("Choose a GSTR-1 section: " + Object.keys(result.sections).join(", ") + ".");
  return csvText(table!.header, table!.rows);
}

export function gstr1Sheets(result: Gstr1): Sheet[] {
  return Object.entries(result.sections).map(([name, table]) => ({
    name, header: table.header, rows: table.rows,
    formats: table.header.map((h) => /Value|Amount/.test(h) ? "money" as const : "number" as const),
  }));
}
