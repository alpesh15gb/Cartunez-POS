// WS-B: A customer's account worked out from the ledger (purchasing.ts partyLedgers).
// Balance > 0: they owe the shop. Balance < 0: money held for them (advances, store credit).
import type { Database, RecordData } from "./db.js";
import { records } from "./db.js";
import { partyLedgers, type LedgerEntry } from "./purchasing.js";

/** Rupees for messages, from paise. */
export const rupees = (paise: number) =>
  "₹" + (paise / 100).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export async function customerLedger(db: Database, org: string, customerId: string) {
  const entries = (await partyLedgers(db, org, "customer")).get(customerId) || [];
  return { entries, balance: entries.length ? entries[entries.length - 1].balance : 0 };
}

/** Money held for the customer that a bill can use: the credit side of their balance. */
export async function availableAdvance(db: Database, org: string, customerId: string) {
  const { balance } = await customerLedger(db, org, customerId);
  return Math.max(0, -balance);
}

/** A customer's credit limit in paise, or null for "no limit set". */
export function creditLimitOf(customer: RecordData | null | undefined): number | null {
  const limit = customer?.creditLimit;
  return typeof limit === "number" && Number.isSafeInteger(limit) && limit >= 0 ? limit : null;
}

export interface DueBill {
  invoiceId: string;
  number: string;
  date: string;
  /** Sold on credit on that bill. */
  amount: number;
  /** Still unpaid (payments settle the oldest bills first). */
  due: number;
  ageDays: number;
}

/** Bills still unpaid, oldest first: the balance is set against the newest credit sales. */
export function dueBills(entries: LedgerEntry[], balance: number, today = new Date()): DueBill[] {
  let left = Math.max(0, balance);
  const due: DueBill[] = [];
  for (const entry of [...entries].reverse()) {
    if (left <= 0) break;
    if (entry.type !== "sale" && entry.type !== "opening") continue;
    if (!entry.debit) continue;
    const share = Math.min(left, entry.debit);
    left -= share;
    due.push({
      invoiceId: entry.type === "sale" ? entry.id : "",
      number: entry.type === "sale" ? entry.reference.replace(/^Invoice /, "") : "Opening balance",
      date: entry.date,
      amount: entry.debit,
      due: share,
      ageDays: Math.max(0, Math.floor((today.getTime() - Date.parse(entry.date + "T00:00:00Z")) / 86400000)),
    });
  }
  return due.reverse();
}

/** Everyone who owes the shop, largest balance first. */
export async function collections(db: Database, org: string) {
  const ledgers = await partyLedgers(db, org, "customer");
  const customers = await records(db, org, "customer");
  const rows = [];
  for (const customer of customers) {
    const entries = ledgers.get(customer.id) || [];
    const balance = entries.length ? entries[entries.length - 1].balance : 0;
    if (balance <= 0) continue;
    const bills = dueBills(entries, balance);
    const lastPayment = [...entries].reverse().find((e) => e.type === "payment");
    const limit = creditLimitOf(customer);
    rows.push({
      customerId: customer.id,
      name: customer.name,
      phone: customer.phone || "",
      balance,
      creditLimit: limit,
      overLimit: limit !== null && balance > limit,
      oldestDueDate: bills[0]?.date || null,
      oldestDueDays: bills[0]?.ageDays ?? 0,
      dueBills: bills.length,
      lastPaymentDate: lastPayment?.date || null,
    });
  }
  return rows.sort((a, b) => b.balance - a.balance);
}
