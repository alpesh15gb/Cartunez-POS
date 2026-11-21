// WS-B: Customers: profile, credit limit, advances, the 360 view and collections.
import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { putRecord, records } from "../db.js";
import { type Actor, allow, approved, audit, fail, id, integer, multiline, now, scoped, text } from "../domain.js";
import { emailAddress } from "../settings.js";
import { availableAdvance, collections, creditLimitOf, customerLedger, dueBills, rupees } from "../customer-account.js";
import { refundAmount } from "../returns.js";

const SELLERS = ["owner", "manager", "cashier"];
const MANAGERS = ["owner", "manager"];
/** How an advance is taken or paid back at the counter. */
export const ADVANCE_MODES = ["Cash", "UPI", "Card"];

function creditLimitInput(value: unknown) {
  if (value === null || value === "" || value === undefined) return null;
  return integer(value, "Credit limit", 0);
}

/** The cashier's open shift; cash advances go through its drawer. */
async function openShift(db: Database, actor: Actor) {
  return (await records(db, actor.organizationId, "shift", actor.branchId)).find((s) => s.userId === actor.id && !s.closedAt) || null;
}

export async function advanceMovement(db: Database, actor: Actor, body: any, customerId: string, refund: boolean) {
  const amount = integer(body.amount, "Amount", 1);
  const mode = String(body.mode || "Cash");
  if (!ADVANCE_MODES.includes(mode)) fail("Choose Cash, UPI or Card.");
  const shift = await openShift(db, actor);
  if (mode === "Cash" && !shift) fail("Open your shift first: cash goes through the drawer.", 409);
  const notes = multiline(body.notes || body.reason || "", "notes", false, 500);
  const record = {
    id: id("payment"),
    shiftId: shift?.id || null,
    branchId: actor.branchId,
    partyKind: "customer",
    partyId: customerId,
    refund,
    direction: refund ? "out" : "in",
    advance: true,
    amount,
    mode,
    reference: text(body.reference || "", "reference", false, 120),
    date: now().slice(0, 10),
    notes: notes ? `Advance · ${notes}` : refund ? "Advance refunded" : "Advance",
    createdAt: now(),
    userId: actor.id,
    voided: false,
  };
  await putRecord(db, actor.organizationId, "partyPayment", record, actor.branchId);
  await audit(db, actor, refund ? "advance-refund" : "advance", record.id,
    `${refund ? "Paid back" : "Received"} advance ${rupees(amount)} by ${mode}`, { customerId });
  return record;
}

export function customerRoutes(app: FastifyInstance, db: Database, post: Post) {
  // Moved from routes/catalog.ts. Saving keeps fields other screens set (credit limit, vehicles).
  post("customers", async (tx, actor, body) => {
    allow(actor, SELLERS);
    const saved = body.id ? await scoped(tx, actor, "customer", body.id) : null;
    const mayEdit = MANAGERS.includes(actor.role);
    const entity: any = {
      ...saved,
      id: body.id || id("customer"),
      name: text(body.name, "name"),
      phone: String(body.phone || ""),
      email: emailAddress(body.email || "", false),
      address: multiline(body.address || "", "address"),
      taxRegistrationId: text(body.taxRegistrationId || "", "tax registration ID", false, 100),
      stateCode: text(body.stateCode || "", "state code", false, 50),
      vehicle: body.vehicle || null,
      // Old balance from before the POS (positive: the customer owes us).
      // Only owners and managers may set it; other edits keep the saved value.
      openingBalance: mayEdit && body.openingBalance !== undefined
        ? integer(body.openingBalance, "Opening balance", -100000000000)
        : Number(saved?.openingBalance || 0),
      openingDate: (mayEdit && body.openingDate ? String(body.openingDate).slice(0, 10) : "") || saved?.openingDate || "",
      creditLimit: mayEdit && body.creditLimit !== undefined ? creditLimitInput(body.creditLimit) : creditLimitOf(saved),
    };
    return putRecord(tx, actor.organizationId, "customer", entity);
  });

  post("customers/:id/credit-limit", async (tx, actor, body, params) => {
    allow(actor, MANAGERS);
    const customer = await scoped(tx, actor, "customer", params.id);
    const creditLimit = creditLimitInput(body.creditLimit);
    const saved = await putRecord(tx, actor.organizationId, "customer", { ...customer, creditLimit });
    await audit(tx, actor, "credit-limit", customer.id,
      creditLimit === null ? "Credit limit removed" : `Credit limit set to ${rupees(creditLimit)}`,
      { before: creditLimitOf(customer), after: creditLimit });
    return saved;
  });

  // Money paid ahead (for a part on order, a booking): held on the account until used.
  post("customers/:id/advances", async (tx, actor, body, params) => {
    allow(actor, SELLERS);
    const customer = await scoped(tx, actor, "customer", params.id);
    return advanceMovement(tx, actor, body, customer.id, false);
  });

  // Giving an advance back needs a manager (a cashier brings an "advance-refund" approval).
  post("customers/:id/advances/refund", async (tx, actor, body, params) => {
    allow(actor, SELLERS);
    const customer = await scoped(tx, actor, "customer", params.id);
    text(body.reason, "reason");
    if (!MANAGERS.includes(actor.role) && !body.approvalId)
      fail("A manager must approve giving an advance back.", 403);
    await approved(tx, actor, "advance-refund", body.approvalId, String(body.transactionId || ""),
      { amount: Number(body.amount), subjectId: customer.id }); // Security: bound approval
    const available = await availableAdvance(tx, actor.organizationId, customer.id);
    const amount = integer(body.amount, "Amount", 1);
    if (amount > available)
      fail(available ? `Only ${rupees(available)} is held for ${customer.name}.` : `${customer.name} has no advance to give back.`, 409);
    return advanceMovement(tx, actor, body, customer.id, true);
  });

  // Customer 360: profile, account, due bills, purchases and returns.
  app.get("/api/v1/customers/:id/summary", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, SELLERS);
    return db.readSnapshot(async (tx) => {
      const customer = await scoped(tx, actor, "customer", String(request.params.id));
      const { entries, balance } = await customerLedger(tx, actor.organizationId, customer.id);
      const invoices = (await records(tx, actor.organizationId, "invoice", actor.branchId))
        .filter((invoice) => invoice.customerId === customer.id)
        .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
      const invoiceIds = new Set(invoices.map((invoice) => invoice.id));
      const returns = (await records(tx, actor.organizationId, "return", actor.branchId))
        .filter((ret) => invoiceIds.has(ret.invoiceId))
        .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
      const advances = entries.filter((entry) => entry.type === "payment" || entry.type === "refund");
      const limit = creditLimitOf(customer);
      return {
        customer,
        balance,
        availableAdvance: Math.max(0, -balance),
        creditLimit: limit,
        creditAvailable: limit === null ? null : Math.max(0, limit - Math.max(0, balance)),
        entries,
        dueBills: dueBills(entries, balance),
        // Vehicles: the customer's saved vehicle until the vehicle registry lists theirs.
        vehicles: Array.isArray(customer.vehicles) ? customer.vehicles : customer.vehicle ? [customer.vehicle] : [],
        stats: {
          bills: invoices.length,
          spent: invoices.reduce((sum, invoice) => sum + invoice.total, 0),
          returned: returns.reduce((sum, ret) => sum + ret.total, 0),
          lastVisit: invoices[0]?.createdAt || null,
        },
        invoices: invoices.slice(0, 100).map((invoice) => ({
          id: invoice.id,
          number: invoice.number,
          createdAt: invoice.createdAt,
          total: invoice.total,
          items: (invoice.lines || []).reduce((sum: number, line: any) => sum + line.qty, 0),
          tenders: (invoice.tenders || []).map((t: any) => ({ type: t.type, amount: t.amount })),
          advanceApplied: invoice.advanceApplied || 0,
        })),
        returns: returns.slice(0, 100).map((ret) => ({
          id: ret.id,
          number: ret.number,
          invoiceId: ret.invoiceId,
          invoiceNumber: ret.invoiceNumber,
          createdAt: ret.createdAt,
          total: ret.total,
          refundType: ret.refundType,
          refund: refundAmount(ret),
          voided: !!ret.voided,
        })),
        advanceMovements: advances.length,
      };
    });
  });

  app.get("/api/v1/collections", async (request: any) => {
    const actor: Actor = request.actor;
    allow(actor, SELLERS);
    return db.readSnapshot(async (tx) => {
      const rows = await collections(tx, actor.organizationId);
      return { rows, total: rows.reduce((sum, row) => sum + row.balance, 0) };
    });
  });
}
