import type { Database, RecordData } from "./db.js";
import type { Actor } from "./domain.js";
import { refundBy, refundParts } from "./returns.js";

// Older releases marked the original payment void. A later void did not change what was in the drawer at close.
function postedAtClose(payment: RecordData, closedAt?: string) {
  return !payment.voided || !!(closedAt && payment.voidedAt && payment.voidedAt > closedAt);
}

/** Read complete shifts, including activity after midnight and before the report's start date. */
export async function shiftCashSummaries(db: Database, actor: Actor, shifts: RecordData[]) {
  if (!shifts.length) return [];
  const closed = new Map(shifts.map(s => [s.id, s.closedAt]));
  const totals = new Map(shifts.map(shift => [shift.id, {
    cashSales: 0, cashRefunds: 0, cashIn: 0, cashOut: 0,
  }]));
  const { rows } = await db.query(
    `SELECT kind, data FROM records WHERE organization_id=$1 AND branch_id=$2
      AND kind IN ('invoice','return','coreReturn','cashMovement','partyPayment')
      AND data->>'shiftId' = ANY($3::text[])`,
    [actor.organizationId, actor.branchId, [...totals.keys()]],
  );
  for (const { kind, data } of rows) {
    const cash = totals.get(data.shiftId)!;
    if (kind === "invoice") {
      for (const tender of data.tenders) {
        if (tender.type === "Cash") cash.cashSales += tender.amount;
      }
      cash.cashSales -= data.change || 0;
    } else if (kind === "partyPayment") {
      // Cash paid to a supplier or received from a customer through this drawer.
      if (postedAtClose(data, closed.get(data.shiftId)) && data.mode === "Cash") {
        if (data.direction === "in") cash.cashIn += data.amount;
        else cash.cashOut += data.amount;
      }
    } else if (kind === "cashMovement") {
      if (data.direction === "in") cash.cashIn += data.amount;
      else cash.cashOut += data.amount;
    } else {
      // Only the cash part of a refund leaves the drawer (per-tender breakdown, returns.ts).
      cash.cashRefunds += refundBy(data, "Cash");
    }
  }
  return shifts.map(shift => {
    const totalsForShift = totals.get(shift.id)!;
    const { cashSales, cashRefunds, cashIn, cashOut } = totalsForShift;
    return {
      ...shift, ...totalsForShift,
      expectedCash: shift.closedAt && shift.expectedCash != null ? shift.expectedCash
        : shift.openingCash + cashSales - cashRefunds + cashIn - cashOut,
    };
  });
}

// WS-D: denominations for the close-shift count (paise per note; coins entered as a paise total).
export const cashNotes = [200000, 50000, 20000, 10000, 5000, 2000, 1000];

function invalid(message: string): never {
  throw Object.assign(new Error(message), { statusCode: 400 });
}

/** Validates a note count ({"50000": 3, ..., coins: 1250}) and returns the non-zero counts with their total. */
export function countDenominations(input: unknown) {
  if (input == null) return null;
  if (typeof input !== "object" || Array.isArray(input)) invalid("Enter the note count as numbers.");
  const counts: Record<string, number> = {};
  let total = 0;
  for (const [key, value] of Object.entries(input as Record<string, unknown>)) {
    const note = key === "coins" ? 1 : Number(key);
    if (key !== "coins" && !cashNotes.includes(note)) invalid("Unknown note " + key + ".");
    if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > 100000000)
      invalid("Note counts must be whole numbers of zero or more.");
    if (!value) continue;
    counts[key] = value;
    total += note * value;
  }
  return { counts, total };
}

/** Everything that went through one shift: sales by tender, refunds, drawer movements and cash party payments. */
export async function shiftSummary(db: Database, actor: Actor, shift: RecordData) {
  const { rows } = await db.query(
    `SELECT kind, data FROM records WHERE organization_id=$1 AND branch_id=$2
      AND kind IN ('invoice','return','coreReturn','cashMovement','partyPayment')
      AND data->>'shiftId' = $3 ORDER BY created_at`,
    [actor.organizationId, actor.branchId, shift.id],
  );
  const tenders: Record<string, number> = {};
  const refunds: Record<string, number> = {};
  let invoices = 0, gross = 0, refundTotal = 0, refundCount = 0, change = 0;
  const cashMovements: any[] = [];
  const partyPayments: any[] = [];
  for (const { kind, data } of rows) {
    if (kind === "invoice") {
      invoices++;
      gross += data.total || 0;
      for (const tender of data.tenders || []) tenders[tender.type] = (tenders[tender.type] || 0) + tender.amount;
      if (data.change) {
        tenders.Cash = (tenders.Cash || 0) - data.change;
        change += data.change;
      }
    } else if (kind === "cashMovement") {
      cashMovements.push({ id: data.id, direction: data.direction, amount: data.amount, reason: data.reason,
        createdAt: data.createdAt, userId: data.userId });
    } else if (kind === "partyPayment") {
      if (postedAtClose(data, shift.closedAt) && data.mode === "Cash")
        partyPayments.push({ id: data.id, partyKind: data.partyKind, partyId: data.partyId, direction: data.direction,
          amount: data.amount, reference: data.reference || "", reversesId: data.reversesId || null,
          notes: data.notes, createdAt: data.createdAt });
    } else {
      // What was paid back, per method; an exchange's applied part shows as "Exchange".
      for (const part of refundParts(data)) refunds[part.type] = (refunds[part.type] || 0) + part.amount;
      if (data.exchangeApplied) refunds.Exchange = (refunds.Exchange || 0) + data.exchangeApplied;
      refundTotal += data.total || 0;
      refundCount++;
    }
  }
  const [cash] = await shiftCashSummaries(db, actor, [shift]);
  return {
    shiftId: shift.id,
    userId: shift.userId,
    openedAt: shift.openedAt,
    closedAt: shift.closedAt || null,
    openingCash: shift.openingCash,
    invoices,
    gross,
    change,
    tenders,
    refunds,
    refundCount,
    refundTotal,
    cashMovements,
    partyPayments,
    cashSales: cash.cashSales,
    cashRefunds: cash.cashRefunds,
    cashIn: cash.cashIn,
    cashOut: cash.cashOut,
    expectedCash: cash.expectedCash,
    countedCash: shift.closedAt ? shift.countedCash : null,
    variance: shift.closedAt ? shift.variance : null,
    denominations: shift.denominations || null,
  };
}
