// WS-F: Tally export.
//
// Format choice: Tally's own XML import (Gateway of Tally > Import > Vouchers /
// Masters). It needs no add-on or third-party import utility, works in Tally
// ERP 9 and TallyPrime, and carries balanced accounting vouchers exactly.
// Vouchers are in "Accounting Invoice" form (ledger entries only, no stock
// items), so the shop's stock stays in the POS and Tally keeps the books.
//
//   sales      : Sales vouchers (counter invoices) and Credit Notes (returns)
//   purchases  : Purchase vouchers (supplier bills) and Debit Notes (returns to supplier)
//   ledgers    : the ledger masters the vouchers use, to import once first
//
// Tally signs: a debit is a negative AMOUNT with ISDEEMEDPOSITIVE=Yes, a credit
// is a positive AMOUNT with ISDEEMEDPOSITIVE=No. Every voucher sums to zero;
// any paise left over from rounding go to "Round Off".
import type { Database } from "../db.js";
import { records } from "../db.js";
import { type Actor, fail } from "../domain.js";
import { exportPeriod, rupeeText, splitOf, taxableOf } from "./common.js";
import { escapeXml } from "./xlsx.js";
import { refundParts } from "../returns.js";

export const LEDGERS = {
  cash: "Cash",
  card: "Card Receipts",
  upi: "UPI Receipts",
  // Paid on the website: held by the payment gateway until it settles to the bank.
  online: "Website Collections",
  cgstOut: "Output CGST", sgstOut: "Output SGST", igstOut: "Output IGST", taxOut: "Output Tax",
  cgstIn: "Input CGST", sgstIn: "Input SGST", igstIn: "Input IGST",
  cores: "Core Deposits",
  roundOff: "Round Off",
  freight: "Freight and Other Charges",
  discountReceived: "Discount Received",
  purchaseReturns: "Purchase Returns",
  walkIn: "Counter Customer",
};

/** Tally group of each ledger name, for the masters file. */
function groupOf(name: string, parties: { customers: Set<string>; suppliers: Set<string> }) {
  if (parties.customers.has(name)) return "Sundry Debtors";
  if (parties.suppliers.has(name)) return "Sundry Creditors";
  if (name === LEDGERS.cash) return "Cash-in-Hand";
  if (name === LEDGERS.card || name === LEDGERS.upi) return "Bank Accounts";
  if (name === LEDGERS.online) return "Current Assets";
  if (/^(Output|Input) /.test(name)) return "Duties & Taxes";
  if (name.startsWith("Sales")) return "Sales Accounts";
  if (name.startsWith("Purchase")) return "Purchase Accounts";
  if (name === LEDGERS.cores) return "Current Liabilities";
  if (name === LEDGERS.freight) return "Indirect Expenses";
  return "Indirect Incomes"; // Round Off, Discount Received
}

type Entry = { ledger: string; amount: number }; // paise; + debit, - credit
interface Voucher { type: string; date: string; number: string; party: string; narration: string; reference?: string; entries: Entry[] }

const tallyDate = (day: string) => day.replace(/-/g, "");
const rateLabel = (rate: number) => `${Number(rate || 0) / 100}%`;

function merge(entries: Entry[]) {
  const map = new Map<string, number>();
  for (const e of entries) if (e.amount) map.set(e.ledger, (map.get(e.ledger) || 0) + e.amount);
  return [...map.entries()].filter(([, a]) => a).map(([ledger, amount]) => ({ ledger, amount }));
}
function balance(entries: Entry[]) {
  const rest = entries.reduce((n, e) => n + e.amount, 0);
  return rest ? [...entries, { ledger: LEDGERS.roundOff, amount: -rest }] : entries;
}

function taxEntries(lines: any[], sign: number, input: boolean, gst: boolean) {
  const out: Entry[] = [];
  for (const line of lines) {
    const split = splitOf(line);
    if (gst && (split.cgst || split.sgst || split.igst)) {
      out.push({ ledger: input ? LEDGERS.cgstIn : LEDGERS.cgstOut, amount: sign * split.cgst });
      out.push({ ledger: input ? LEDGERS.sgstIn : LEDGERS.sgstOut, amount: sign * split.sgst });
      out.push({ ledger: input ? LEDGERS.igstIn : LEDGERS.igstOut, amount: sign * split.igst });
    } else out.push({ ledger: LEDGERS.taxOut, amount: sign * Number(line.tax || 0) });
  }
  return out;
}

/**
 * Ledger a tender (or refund method) posts to. Credit (on account), Advance
 * (money already held for the customer, so it reduces their advance) and
 * Exchange (credit note set against the bill) all post to the customer's own
 * ledger; Online goes to the website collections ledger so website customers
 * are not left owing.
 */
const receiptLedger = (type: string, customer: string) =>
  type === "Cash" ? LEDGERS.cash
    : type === "Card" ? LEDGERS.card
      : type === "UPI" ? LEDGERS.upi
        : type === "Online" ? LEDGERS.online
          : customer;

export async function tallyVouchers(db: Database, actor: Actor, query: any) {
  const period = await exportPeriod(db, actor, query);
  const kind = String(query.vouchers || "all");
  if (!["sales", "purchases", "all", "ledgers"].includes(kind)) fail("Choose sales, purchases, all or ledgers.");
  const gst = period.settings.taxScheme === "india-gst";
  const vouchers: Voucher[] = [];
  const parties = { customers: new Set<string>([LEDGERS.walkIn]), suppliers: new Set<string>() };

  if (kind !== "purchases") {
    const invoices = await period.load("invoice");
    const byId = new Map(invoices.map((i) => [i.id, i]));
    for (const invoice of invoices.filter((i) => period.inPeriod(i.createdAt))) {
      const customer = invoice.customer?.name ? String(invoice.customer.name) : LEDGERS.walkIn;
      parties.customers.add(customer);
      const entries: Entry[] = [];
      for (const tender of invoice.tenders || [])
        entries.push({ ledger: receiptLedger(tender.type, customer), amount: tender.amount });
      if (invoice.change) entries.push({ ledger: LEDGERS.cash, amount: -invoice.change });
      for (const line of invoice.lines)
        entries.push({ ledger: `Sales ${gst ? "@ " + rateLabel(line.taxRate) : ""}`.trim(), amount: -taxableOf(line) });
      entries.push(...taxEntries(invoice.lines, -1, false, gst));
      if (invoice.coreTotal) entries.push({ ledger: LEDGERS.cores, amount: -invoice.coreTotal });
      vouchers.push({ type: "Sales", date: period.businessDay(invoice.createdAt), number: invoice.number, party: customer,
        narration: `POS invoice ${invoice.number}`, entries: balance(merge(entries)) });
    }
    for (const credit of (await period.load("return")).filter((r) => period.inPeriod(r.createdAt))) {
      const original = byId.get(credit.invoiceId);
      const name = credit.customer?.name || original?.customer?.name;
      const customer = name ? String(name) : LEDGERS.walkIn;
      parties.customers.add(customer);
      const total = credit.lines.reduce((n: number, l: any) => n + l.total, 0);
      // Paid back per method (refunds breakdown); the part set against an
      // exchange bill credits the customer, whose ledger that bill debits.
      const parts = refundParts(credit);
      const applied = Number(credit.exchangeApplied || 0);
      const entries: Entry[] = parts.map((part) => ({ ledger: receiptLedger(part.type, customer), amount: -part.amount }));
      if (applied) entries.push({ ledger: customer, amount: -applied });
      // Older credit notes: whatever the breakdown does not cover went by refundType.
      const rest = total - applied - parts.reduce((n, part) => n + part.amount, 0);
      if (rest) entries.push({ ledger: receiptLedger(credit.refundType === "Exchange" ? "Credit" : credit.refundType || "Cash", customer), amount: -rest });
      for (const line of credit.lines)
        entries.push({ ledger: `Sales ${gst ? "@ " + rateLabel(line.taxRate) : ""}`.trim(), amount: taxableOf(line) });
      entries.push(...taxEntries(credit.lines, 1, false, gst));
      vouchers.push({ type: "Credit Note", date: period.businessDay(credit.createdAt), number: credit.number, party: customer,
        reference: credit.invoiceNumber, narration: `${credit.voided ? "Void of" : "Return on"} invoice ${credit.invoiceNumber}: ${credit.reason || ""}`.trim(),
        entries: balance(merge(entries)) });
    }
  }
  if (kind !== "sales") {
    const inBillPeriod = (day: string) => day >= period.dateFrom && day <= period.dateTo;
    for (const bill of (await period.load("purchaseBill")).filter((b) => !b.voided && inBillPeriod(String(b.billDate)))) {
      const supplier = String(bill.supplierName || bill.supplierId);
      parties.suppliers.add(supplier);
      const entries: Entry[] = [{ ledger: supplier, amount: -bill.total }];
      for (const line of bill.lines)
        entries.push({ ledger: bill.gst ? `Purchase @ ${rateLabel(line.taxRate)}` : "Purchases", amount: line.amount });
      if (bill.gst) {
        for (const line of bill.lines) {
          if (bill.interState) entries.push({ ledger: LEDGERS.igstIn, amount: line.tax });
          else {
            const half = Math.round(line.tax / 2);
            entries.push({ ledger: LEDGERS.cgstIn, amount: half }, { ledger: LEDGERS.sgstIn, amount: line.tax - half });
          }
        }
      }
      if (bill.otherCharges) entries.push({ ledger: LEDGERS.freight, amount: bill.otherCharges });
      if (bill.discount) entries.push({ ledger: LEDGERS.discountReceived, amount: -bill.discount });
      vouchers.push({ type: "Purchase", date: String(bill.billDate), number: bill.billNumber || bill.id, party: supplier,
        reference: bill.billNumber || "", narration: `Supplier bill ${bill.billNumber || "(no number)"}`, entries: balance(merge(entries)) });
    }
    const supplierNames = new Map((await records(db, actor.organizationId, "supplier")).map((s) => [s.id, s.name]));
    for (const ret of (await period.load("purchaseReturn")).filter((r) => inBillPeriod(String(r.date)))) {
      const supplier = String(supplierNames.get(ret.supplierId) || ret.supplierId);
      parties.suppliers.add(supplier);
      vouchers.push({ type: "Debit Note", date: String(ret.date), number: ret.id, party: supplier, reference: ret.billNumber || "",
        narration: `Returned to supplier: ${ret.reason || ""}`.trim(),
        entries: [{ ledger: supplier, amount: ret.total }, { ledger: LEDGERS.purchaseReturns, amount: -ret.total }] });
    }
  }
  // Party ledgers are listed even when paid in full, so PARTYLEDGERNAME always exists in Tally.
  const ledgers = [...new Set(vouchers.flatMap((v) => [v.party, ...v.entries.map((e) => e.ledger)]))].sort()
    .map((name) => ({ name, group: groupOf(name, parties) }));
  return { vouchers, ledgers, kind };
}

export type TallyExport = Awaited<ReturnType<typeof tallyVouchers>>;

function envelope(report: "Vouchers" | "All Masters", messages: string[]) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<ENVELOPE>
 <HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER>
 <BODY>
  <IMPORTDATA>
   <REQUESTDESC><REPORTNAME>${report}</REPORTNAME></REQUESTDESC>
   <REQUESTDATA>
${messages.join("\n")}
   </REQUESTDATA>
  </IMPORTDATA>
 </BODY>
</ENVELOPE>
`;
}

export function tallyXml(result: TallyExport) {
  const x = escapeXml;
  if (result.kind === "ledgers")
    return envelope("All Masters", result.ledgers.map((l) =>
      `    <TALLYMESSAGE xmlns:UDF="TallyUDF"><LEDGER NAME="${x(l.name)}" ACTION="Create"><NAME>${x(l.name)}</NAME><PARENT>${x(l.group)}</PARENT>` +
      `${l.group === "Duties & Taxes" ? "<TAXTYPE>GST</TAXTYPE>" : ""}<ISBILLWISEON>${/Sundry/.test(l.group) ? "Yes" : "No"}</ISBILLWISEON></LEDGER></TALLYMESSAGE>`));
  return envelope("Vouchers", result.vouchers.map((v) => {
    const entries = v.entries.map((e) =>
      `      <ALLLEDGERENTRIES.LIST><LEDGERNAME>${x(e.ledger)}</LEDGERNAME><ISDEEMEDPOSITIVE>${e.amount > 0 ? "Yes" : "No"}</ISDEEMEDPOSITIVE>` +
      `<AMOUNT>${rupeeText(-e.amount)}</AMOUNT></ALLLEDGERENTRIES.LIST>`).join("\n");
    return `    <TALLYMESSAGE xmlns:UDF="TallyUDF">
     <VOUCHER VCHTYPE="${x(v.type)}" ACTION="Create" OBJVIEW="Accounting Voucher View">
      <DATE>${tallyDate(v.date)}</DATE>
      <VOUCHERTYPENAME>${x(v.type)}</VOUCHERTYPENAME>
      <VOUCHERNUMBER>${x(v.number)}</VOUCHERNUMBER>
      <PARTYLEDGERNAME>${x(v.party)}</PARTYLEDGERNAME>
      ${v.reference ? `<REFERENCE>${x(v.reference)}</REFERENCE>` : ""}
      <NARRATION>${x(v.narration)}</NARRATION>
      <PERSISTEDVIEW>Accounting Voucher View</PERSISTEDVIEW>
${entries}
     </VOUCHER>
    </TALLYMESSAGE>`;
  }));
}
