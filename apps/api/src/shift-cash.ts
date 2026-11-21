import type { Database, RecordData } from "./db.js";
import type { Actor } from "./domain.js";

/** Read complete shifts, including activity after midnight and before the report's start date. */
export async function shiftCashSummaries(db: Database, actor: Actor, shifts: RecordData[]) {
  if (!shifts.length) return [];
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
      if (!data.voided && data.mode === "Cash") {
        if (data.direction === "in") cash.cashIn += data.amount;
        else cash.cashOut += data.amount;
      }
    } else if (kind === "cashMovement") {
      if (data.direction === "in") cash.cashIn += data.amount;
      else cash.cashOut += data.amount;
    } else if ((data.refundType ?? "Cash") === "Cash") {
      // WS-B: an exchange credit note pays back only its refundTotal.
      cash.cashRefunds += data.refundTotal ?? data.total;
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
