// Purchasing and party balances.
//   Purchase bill   : what a supplier delivered and charges (stock in, supplier balance up).
//                     Most bills have no GST; a bill can be marked as a GST bill.
//   Purchase return : parts sent back to a supplier (stock out, supplier balance down).
//   Party payment   : money paid to a supplier or received from a customer.
//   Customer credit : a counter sale with the "Credit" tender raises the customer's
//                     balance; a return refunded to "Credit" lowers it.
//   Attachments     : photos of supplier notes and bills (base64 records, so they are
//                     in the existing backups).
// Balances are worked out from these records each time, so they always agree with them.
import type { FastifyInstance } from "fastify";
import type { Database, RecordData } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { adjust, allow, audit, fail, id, integer, inventory, reservingHolds, multiline, now, scoped, text, roundRatio, type Actor } from "./domain.js";
import type { Post } from "./routes/types.js";
import { captureBillEconomics, claimBillEconomics, landedLineTotals, productValues, restoreBillEconomics, type BillEconomics } from "./bill-economics.js";
import { noteCost } from "./cost-changes.js"; // WS-E
import { queueMagentoSync } from "./online-queue.js";
import { refundBy } from "./returns.js"; // money and stock review: per-tender refunds


export const PAYMENT_MODES = ["Cash", "UPI", "Bank transfer", "Cheque", "Card"];
const STOCK_ROLES = ["owner", "manager", "inventory"];
// Base64 adds a third, and requests are limited to 4 MiB.
const MAX_ATTACHMENT = 2_900_000;
const MAX_BILL_PHOTOS = 6;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const EXTENSIONS: Record<string, string> = { "image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "application/pdf": ".pdf" };

/** A header-safe download name: letters, digits, dot, dash and underscore, with the right extension. */
function safeFileName(file: Record<string, any>) {
  const extension = EXTENSIONS[file.contentType] || "";
  const base = String(file.name || "").replace(/\.[^.]*$/, "").replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 80);
  return (base || "file") + extension;
}

/** Security: a cashier sees a photo on a job card of their branch or a vehicle, or their own upload — never a bill's. */
async function sellerMaySee(db: Database, actor: Actor, file: Record<string, any>) {
  const photo = JSON.stringify([{ id: file.id }]);
  const onBill = await db.query(
    "SELECT 1 FROM records WHERE organization_id=$1 AND kind IN ('purchaseBill','purchaseReturn') AND data->'photos' @> $2::jsonb LIMIT 1",
    [actor.organizationId, photo],
  );
  if (onBill.rows.length) return false;
  if (file.userId === actor.id) return true;
  const shown = await db.query(
    "SELECT 1 FROM records WHERE organization_id=$1 AND ((kind='job' AND branch_id=$3) OR kind='customerVehicle') " +
      "AND data->'photos' @> $2::jsonb LIMIT 1",
    [actor.organizationId, photo, actor.branchId],
  );
  return shown.rows.length > 0;
}

const day = (value: unknown, label: string) => {
  const s = String(value ?? "").slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s) || Number.isNaN(Date.parse(s))) fail(`Enter the ${label} as a date.`);
  return s;
};

export interface LedgerEntry {
  date: string;
  at: string;
  type: "opening" | "bill" | "purchase-return" | "payment" | "refund" | "sale" | "sale-return" | "void";
  id: string;
  reference: string;
  note: string;
  /** Raises the balance: we owe the supplier more / the customer owes us more. */
  debit: number;
  /** Lowers the balance. */
  credit: number;
  balance: number;
  reversible?: boolean;
}

/**
 * Every party's ledger. Supplier balance = what we owe them; customer balance =
 * what they owe us. Negative means an advance (we paid ahead / they paid ahead).
 */
export async function partyLedgers(db: Database, org: string, kind: "supplier" | "customer") {
  const parties = await records(db, org, kind);
  const entries = new Map<string, Omit<LedgerEntry, "balance">[]>();
  const add = (partyId: string | null | undefined, entry: Omit<LedgerEntry, "balance">) => {
    if (!partyId) return;
    if (!entries.has(partyId)) entries.set(partyId, []);
    entries.get(partyId)!.push(entry);
  };
  for (const party of parties) {
    const opening = Number(party.openingBalance || 0);
    if (opening)
      add(party.id, {
        date: String(party.openingDate || "").slice(0, 10) || "0000-00-00",
        at: "",
        type: "opening",
        id: party.id,
        reference: "Opening balance",
        note: "",
        debit: Math.max(opening, 0),
        credit: Math.max(-opening, 0),
      });
  }
  const payments = await records(db, org, "partyPayment");
  const reversedIds = new Set(payments.map(p => p.reversesId).filter(Boolean));
  for (const payment of payments) {
    if (payment.partyKind !== kind || payment.voided) continue;
    // A refund goes the other way: money given back to a customer, or received back from a supplier.
    add(payment.partyId, {
      date: payment.date,
      at: payment.createdAt,
      type: payment.reversesId ? "void" : payment.refund ? "refund" : "payment",
      reversible: !payment.reversesId && !reversedIds.has(payment.id),
      id: payment.id,
      // WS-B: advances (routes/customers.ts) are labelled as such.
      reference: [payment.reversesId ? "Payment reversal" : payment.advance ? (payment.refund ? "Advance refund" : "Advance") : "", payment.mode, payment.reference].filter(Boolean).join(" · "),
      note: payment.notes || "",
      debit: payment.refund ? payment.amount : 0,
      credit: payment.refund ? 0 : payment.amount,
    });
  }
  if (kind === "supplier") {
    for (const bill of await records(db, org, "purchaseBill")) {
      if (bill.voided) continue;
      add(bill.supplierId, {
        date: bill.billDate,
        at: bill.createdAt,
        type: "bill",
        id: bill.id,
        reference: bill.billNumber ? `Bill ${bill.billNumber}` : "Purchase bill",
        note: `${bill.lines.length} item(s)${bill.gst ? " · GST bill" : ""}`,
        debit: bill.total,
        credit: 0,
      });
    }
    for (const ret of await records(db, org, "purchaseReturn")) {
      add(ret.supplierId, {
        date: ret.date,
        at: ret.createdAt,
        type: "purchase-return",
        id: ret.id,
        reference: ret.billNumber ? `Return against bill ${ret.billNumber}` : "Return to supplier",
        note: ret.reason || "",
        debit: 0,
        credit: ret.total,
      });
    }
  } else {
    for (const invoice of await records(db, org, "invoice")) {
      const onCredit = (invoice.tenders || [])
        .filter((t: any) => t.type === "Credit")
        .reduce((n: number, t: any) => n + t.amount, 0);
      // WS-B: money held for the customer used on this bill (hooks/advance.ts).
      const fromAdvance = (invoice.tenders || [])
        .filter((t: any) => t.type === "Advance")
        .reduce((n: number, t: any) => n + t.amount, 0);
      if (fromAdvance)
        add(invoice.customerId, {
          date: String(invoice.createdAt).slice(0, 10),
          at: invoice.createdAt,
          type: "sale",
          id: invoice.id + ":advance",
          reference: `Invoice ${invoice.number}`,
          note: "Advance used",
          debit: fromAdvance,
          credit: 0,
        });
      if (!onCredit) continue;
      add(invoice.customerId, {
        date: String(invoice.createdAt).slice(0, 10),
        at: invoice.createdAt,
        type: "sale",
        id: invoice.id,
        reference: `Invoice ${invoice.number}`,
        note: "Sold on credit",
        debit: onCredit,
        credit: 0,
      });
    }
    for (const core of await records(db, org, "coreReturn")) {
      // Money and stock review: the account part of the per-tender refund breakdown.
      const coreCredit = refundBy(core, "Credit");
      if (!coreCredit) continue;
      const invoice = await getRecord(db, org, "invoice", core.invoiceId);
      add(invoice?.customerId, {
        date: String(core.createdAt).slice(0, 10),
        at: core.createdAt,
        type: "sale-return",
        id: core.id,
        reference: `Core deposit on invoice ${invoice?.number || ""}`.trim(),
        note: core.reason || "",
        debit: 0,
        credit: coreCredit,
      });
    }
    for (const ret of await records(db, org, "return")) {
      // WS-B: an exchange credits the account only with what was not set against the new bill;
      // a mixed refund only with its account part (per-tender breakdown, returns.ts).
      const amount = refundBy(ret, "Credit");
      if (!amount) continue;
      const invoice = await getRecord(db, org, "invoice", ret.invoiceId);
      add(invoice?.customerId, {
        date: String(ret.createdAt).slice(0, 10),
        at: ret.createdAt,
        type: ret.voided ? "void" : "sale-return",
        id: ret.id,
        reference: `${ret.voided ? "Void of" : "Return on"} invoice ${ret.invoiceNumber}`,
        note: ret.reason || "",
        debit: 0,
        credit: amount,
      });
    }
  }
  const result = new Map<string, LedgerEntry[]>();
  for (const party of parties) {
    let balance = 0;
    const list = (entries.get(party.id) || [])
      .sort((a, b) => a.date.localeCompare(b.date) || a.at.localeCompare(b.at))
      .map((e) => ({ ...e, balance: (balance += e.debit - e.credit) }));
    result.set(party.id, list);
  }
  return result;
}

export async function partyBalances(db: Database, org: string, kind: "supplier" | "customer") {
  const balances: Record<string, number> = {};
  for (const [partyId, list] of await partyLedgers(db, org, kind))
    balances[partyId] = list.length ? list[list.length - 1].balance : 0;
  return balances;
}

type CreditLine = { source: RecordData; net: number; returned: number; credited: number };
type CreditAllocation = { line: CreditLine; quantity: number; serials: string[] };

/** Allocate unidentified historical or website-only returns in original bill order. */
function allocateReturn(candidates: CreditLine[], quantity: number, serials: string[]) {
  const allocations: CreditAllocation[] = [];
  let remaining = quantity;
  for (const line of candidates) {
    const matching = serials.filter(serial => line.source.serials?.includes(serial));
    const take = Math.min(remaining, line.source.quantity - line.returned, serials.length ? matching.length : quantity);
    if (take > 0) allocations.push({ line, quantity: take, serials: matching.slice(0, take) });
    remaining -= take;
    if (!remaining) break;
  }
  return { allocations, remaining };
}

function billCreditLines(bill: RecordData, earlier: RecordData[]) {
  const gross = (l: RecordData) => Number(l.amount ?? l.quantity * l.cost) +
    Number(l.tax ?? (bill.gst ? roundRatio(l.quantity * l.cost, l.taxRate || 0, 10000) : 0));
  const totalGross = bill.lines.reduce((sum: number, l: RecordData) => sum + gross(l), 0);
  let cumulative = 0;
  const lines: CreditLine[] = bill.lines.map((source: RecordData) => {
    const value = gross(source);
    const discount = Math.min(totalGross, source.onlineOnly ? bill.discount || 0
      : Math.max(0, (bill.discount || 0) - (bill.otherCharges || 0)));
    const share = totalGross ? roundRatio(discount, cumulative + value, totalGross) - roundRatio(discount, cumulative, totalGross) : 0;
    cumulative += value;
    return { source, net: value - share, returned: 0, credited: 0 };
  });
  for (const old of earlier) {
    const candidates = lines.filter(l => l.source.productId === old.productId && (!old.billLineId || l.source.id === old.billLineId));
    const { allocations } = allocateReturn(candidates, old.quantity, old.serials || []);
    let quantity = 0;
    const amount = old.amount ?? old.cost * old.quantity;
    for (const allocation of allocations) {
      const next = quantity + allocation.quantity;
      allocation.line.returned += allocation.quantity;
      allocation.line.credited += roundRatio(amount, next, old.quantity) - roundRatio(amount, quantity, old.quantity);
      quantity = next;
    }
  }
  return lines;
}

/** Bill totals. GST (when the bill has it) is added per line on the cost before GST. */
function billTotals(lines: any[], gst: boolean, otherCharges: number, discount: number) {
  let subtotal = 0,
    tax = 0;
  for (const line of lines) {
    line.amount = line.quantity * line.cost;
    if (!Number.isSafeInteger(line.amount)) fail("The purchase line amount is too large.");
    line.tax = gst ? roundRatio(line.amount, line.taxRate, 10000) : 0;
    subtotal += line.amount;
    tax += line.tax;
  }
  if (!Number.isSafeInteger(subtotal + tax + otherCharges)) fail("The purchase bill amount is too large.");
  const total = subtotal + tax + otherCharges - discount;
  if (total < 0) fail("The discount is larger than the bill.");
  return { subtotal, tax, total };
}

/** WS-E: exported for cash-on-delivery collections (fulfilment.ts). */
export async function payment(db: Database, actor: Actor, body: any, partyKind: "supplier" | "customer", partyId: string, extra: any = {}) {
  const amount = integer(body.amount, "Amount", 1);
  const mode = String(body.mode || "Cash");
  if (!PAYMENT_MODES.includes(mode)) fail("Choose how the money was paid.");
  // Cash taken or paid at the counter goes through the user's open cash drawer,
  // so the shift's expected cash stays right. (fromDrawer: false for cash kept elsewhere.)
  const fromDrawer = mode === "Cash" && (body.fromDrawer !== false || (partyKind === "customer" && !extra.onlineOrderId));
  const shift = fromDrawer
    ? (await records(db, actor.organizationId, "shift", actor.branchId)).find((s) => s.userId === actor.id && !s.closedAt)
    : null;
  if (fromDrawer && !shift) fail("Open your shift before recording cash in or out of the drawer.", 409);
  const record = {
    id: id("payment"),
    shiftId: shift?.id || null,
    ...(mode === "Cash" && { fromDrawer }),
    branchId: actor.branchId,
    partyKind,
    partyId,
    refund: body.refund === true,
    direction: (partyKind === "supplier") !== (body.refund === true) ? "out" : "in",
    amount,
    mode,
    reference: text(body.reference || "", "reference", false, 120),
    date: body.date ? day(body.date, "payment date") : now().slice(0, 10),
    notes: multiline(body.notes || "", "notes"),
    createdAt: now(),
    userId: actor.id,
    voided: false,
    ...extra,
  };
  await putRecord(db, actor.organizationId, "partyPayment", record, actor.branchId);
  await audit(db, actor, partyKind === "supplier" ? "supplier-payment" : "customer-payment", record.id,
    `${record.direction === "out" ? "Paid" : "Received"} ${amount} by ${mode}${record.refund ? " (refund)" : ""}`);
  return record;
}

/** Supplier documents can withdraw only free stock from their stated bin.
 * Use one reservation snapshot for the whole document and consume it per line. */
async function supplierWithdrawal(db: Database, actor: Actor) {
  const stock = await inventory(db, actor);
  const free = new Map(stock.map((row) => [row.productId + "|" + row.binId, row.available]));
  const heldSerials = new Set<string>();
  for (const hold of await reservingHolds(db, actor.organizationId, actor.branchId)) {
    for (const line of hold.cart?.lines || []) {
      for (const serial of line.serials || []) heldSerials.add(line.productId + ":" + serial);
    }
  }
  return async (productId: string, binId: string, qty: number, serials: string[], reason: string, reference: string) => {
    const key = productId + "|" + binId;
    const available = free.get(key) || 0;
    if (qty > available) fail("There are insufficient unreserved units in the selected bin for this withdrawal.", 409);
    for (const serial of serials) {
      const serialId = productId + ":" + serial;
      if (heldSerials.has(serialId)) fail("Serial " + serial + " is reserved by a parked sale or job card.", 409);
      const removed = await db.query(
        `DELETE FROM records WHERE organization_id=$1 AND branch_id=$2 AND kind='serial' AND id=$3
           AND data->>'status'='available' AND data->>'binId'=$4 RETURNING id`,
        [actor.organizationId, actor.branchId, serialId, binId],
      );
      if (!removed.rows.length) fail("Serial " + serial + " is no longer available in the selected bin.", 409);
    }
    await adjust(db, actor, productId, binId, -qty, reason, reference);
    free.set(key, available - qty);
  };
}

export function purchasingRoutes(app: FastifyInstance, db: Database, post: Post) {
  // ---------- Attachments (photos of supplier notes and bills) ----------
  // Security: stock roles handle every attachment. Cashiers may upload photos
  // (job card and vehicle photos) and read only photos on a job card of their
  // branch or a vehicle, or their own uploads — never a supplier bill.
  post("attachments", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory", "cashier"]);
    const contentType = String(body.contentType || "");
    const photoTypes = ["image/jpeg", "image/png", "image/webp"];
    if (actor.role === "cashier" && !photoTypes.includes(contentType))
      fail("Use a photo (JPEG, PNG or WebP).", 403);
    if (![...photoTypes, "application/pdf"].includes(contentType))
      fail("Use a photo (JPEG, PNG, WebP) or a PDF.");
    if (typeof body.data !== "string" || body.data.length > MAX_ATTACHMENT * 1.4) fail("The file is too large (about 2.9 MB at most). Photos are shrunk automatically; split large PDFs.");
    const bytes = Buffer.from(body.data, "base64");
    if (!bytes.length || bytes.length > MAX_ATTACHMENT) fail("The file is too large (about 2.9 MB at most).");
    const ascii = (start: number, end: number) => bytes.subarray(start, end).toString("latin1");
    const looksRight =
      contentType === "application/pdf" ? ascii(0, 5) === "%PDF-"
      : contentType === "image/jpeg" ? bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff
      : contentType === "image/png" ? bytes.subarray(0, 8).equals(PNG_SIGNATURE)
      : bytes.length >= 16 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP";
    if (!looksRight) fail("That file is not a valid photo or PDF.");
    const attachment = {
      id: id("file"),
      contentType,
      size: bytes.length,
      name: text(body.name || "", "file name", false, 200),
      createdAt: now(),
      userId: actor.id,
      data: bytes.toString("base64"),
    };
    await putRecord(tx, actor.organizationId, "attachment", attachment);
    const { data, ...meta } = attachment;
    return meta;
  });

  app.get("/api/v1/attachments/:id", async (request: any, reply) => {
    const actor: Actor = request.actor;
    const file = await getRecord(db, actor.organizationId, "attachment", String(request.params.id));
    if (!file) fail("File not found.", 404);
    if (!STOCK_ROLES.includes(actor.role) && !(await sellerMaySee(db, actor, file!))) fail("File not found.", 404);
    reply.header("Content-Type", file!.contentType);
    reply.header("X-Content-Type-Options", "nosniff");
    reply.header("Content-Disposition", `inline; filename="${safeFileName(file!)}"`);
    reply.header("Cache-Control", "private, max-age=31536000, immutable");
    return reply.send(Buffer.from(file!.data, "base64"));
  });

  // ---------- Purchase bills ----------
  post("purchase-bills", async (tx, actor, body) => {
    allow(actor, STOCK_ROLES);
    const supplier = await scoped(tx, actor, "supplier", body.supplierId);
    if (!Array.isArray(body.lines) || !body.lines.length) fail("Add the items on the bill.");
    if (body.lines.length > 300) fail("A bill can have 300 lines at most.");
    const gst = body.gst === true;
    const billNumber = text(body.billNumber || "", "bill number", false, 60);
    const billDate = day(body.billDate || now(), "bill date");
    if (billNumber) {
      const clash = (await records(tx, actor.organizationId, "purchaseBill")).find(
        (b) => !b.voided && b.supplierId === supplier.id && String(b.billNumber).toLowerCase() === billNumber.toLowerCase(),
      );
      if (clash) fail(`Bill ${billNumber} from ${supplier.name} is already entered.`, 409);
    }
    const otherCharges = integer(body.otherCharges || 0, "Freight / other charges");
    const discount = integer(body.discount || 0, "Discount");
    const photoIds = Array.isArray(body.photoIds) ? body.photoIds.map(String) : [];
    if (photoIds.length > MAX_BILL_PHOTOS) fail(`Attach ${MAX_BILL_PHOTOS} photos at most.`);
    const photos = [];
    for (const photoId of photoIds) {
      const file = await getRecord(tx, actor.organizationId, "attachment", photoId);
      if (!file) fail("A bill photo was not uploaded. Add it again.");
      photos.push({ id: file!.id, contentType: file!.contentType, name: file!.name || "" });
    }
    const order = body.purchaseOrderId ? await scoped(tx, actor, "purchaseOrder", body.purchaseOrderId) : null;
    if (order && order.supplierId !== supplier.id) fail("That purchase order is for another supplier.");
    if (order?.status === "cancelled") fail("That purchase order was cancelled."); // WS-E

    const billId = id("bill");
    const lines: any[] = [];
    for (const input of body.lines) {
      const product = await scoped(tx, actor, "product", input.productId);
      if (product.type === "service") fail(`${product.name} is a service, not a stock part.`);
      // Online only: billed and owed to the supplier as usual, but the goods go
      // straight out to the website customer: no bin, no shop stock.
      const onlineOnly = !!product.onlineOnly;
      const bin = onlineOnly ? null : await scoped(tx, actor, "location", input.binId);
      if (bin && bin.kind !== "sellable") fail("Put purchased stock into a sellable bin.");
      if (order) {
        const ordered = order.lines.find((l: any) => l.productId === product.id);
        const outstanding = ordered ? ordered.quantity - (ordered.received || 0) : null;
        const earlier = body.lines.slice(0, body.lines.indexOf(input)).filter((l: any) => l.productId === product.id)
          .reduce((n: number, l: any) => n + Number(l.quantity || 0), 0);
        if (outstanding != null && Number(input.quantity) + earlier > outstanding)
          fail(`Only ${Math.max(outstanding - earlier, 0)} of ${product.name} are still due on that purchase order (the rest was already received).`);
      }
      const line = {
        id: id("billline"),
        productId: product.id,
        sku: product.sku,
        name: product.name,
        quantity: integer(input.quantity, "Quantity", 1, 1000000),
        cost: integer(input.cost, "Unit cost"),
        taxRate: gst ? integer(input.taxRate ?? 0, "GST rate", 0, 4000) : 0,
        binId: bin?.id || null,
        ...(onlineOnly ? { onlineOnly: true } : {}),
        serials: [] as string[],
        mrp: input.retailPrice != null && input.retailPrice !== "" ? integer(input.retailPrice, "Selling price") : null,
      };
      if (product.serialTracked) {
        const serials = Array.isArray(input.serials) ? input.serials.map((s: any) => text(s, "serial")) : [];
        if (serials.length !== line.quantity || new Set(serials).size !== line.quantity)
          fail(`Enter one serial number per unit for ${product.name}.`);
        line.serials = serials;
      }
      lines.push(line);
    }
    const totals = billTotals(lines, gst, otherCharges, discount);
    const landed = landedLineTotals(lines, otherCharges, discount);
    const productEconomics = new Map<string, BillEconomics>();
    for (const [index, line] of lines.entries()) {
      const product = await scoped(tx, actor, "product", line.productId);
      const economics = productEconomics.get(product.id) ?? await captureBillEconomics(tx, actor.organizationId, product);
      line.landedTotal = landed[index];
      line.landedCost = roundRatio(line.landedTotal, 1, line.quantity);
      // WS-E: flag a supplier cost hike against the last purchase cost.
      const hike = await noteCost(tx, actor, product, line.cost, {
        kind: "bill", id: billId, label: billNumber ? `Bill ${billNumber}` : "Purchase bill", supplierId: supplier.id,
      });
      if (hike) line.costHike = hike;
      product.cost = line.landedCost;
      if (line.mrp != null) product.retailPrice = line.mrp;
      economics.after = productValues(product);
      productEconomics.set(product.id, economics);
      await putRecord(tx, actor.organizationId, "product", product);
      for (const serial of line.serials) {
        const serialId = product.id + ":" + serial;
        if (await getRecord(tx, actor.organizationId, "serial", serialId)) fail(`Serial ${serial} already exists.`);
        await putRecord(tx, actor.organizationId, "serial",
          { id: serialId, branchId: actor.branchId, productId: product.id, serial, binId: line.binId, status: "available" }, actor.branchId);
      }
      if (!line.onlineOnly) await adjust(tx, actor, product.id, line.binId, line.quantity, "Purchase bill", billId);
      if (order) {
        const ordered = order.lines.find((l: any) => l.productId === product.id);
        if (ordered) ordered.received = Math.min(ordered.quantity, (ordered.received || 0) + line.quantity);
      }
    }
    if (order) {
      order.status = order.lines.every((l: any) => l.received >= l.quantity) ? "received"
        : order.lines.some((l: any) => l.received > 0) ? "partial" : order.status;
      await putRecord(tx, actor.organizationId, "purchaseOrder", order, actor.branchId);
    }
    const retailUpdates = new Set(lines.filter(line => line.mrp != null).map(line => line.productId));
    for (const economics of productEconomics.values())
      await claimBillEconomics(tx, actor.organizationId, billId, economics, retailUpdates.has(economics.productId));
    if (retailUpdates.size) await queueMagentoSync(tx, actor.organizationId, retailUpdates, "Supplier bill selling price");
    const bill = {
      id: billId,
      branchId: actor.branchId,
      supplierId: supplier.id,
      supplierName: supplier.name,
      billNumber,
      billDate,
      gst,
      interState: gst && body.interState === true,
      purchaseOrderId: order?.id || null,
      lines,
      productEconomics: [...productEconomics.values()],
      otherCharges,
      discount,
      ...totals,
      photoIds,
      photos,
      notes: multiline(body.notes || "", "notes"),
      createdAt: now(),
      userId: actor.id,
      voided: false,
    };
    (bill as any).costHikes = lines.filter((l) => l.costHike).length; // WS-E
    await putRecord(tx, actor.organizationId, "purchaseBill", bill, actor.branchId);
    await audit(tx, actor, "purchase-bill", billId, `Bill ${billNumber || "(no number)"} from ${supplier.name}`, { total: totals.total });
    const paidNow = body.paidNow == null ? 0 : integer(body.paidNow.amount, "Amount paid now");
    if (paidNow > 0) {
      if (paidNow > totals.total) fail("The amount paid now is more than the bill.");
      await payment(tx, actor, {
        amount: paidNow,
        mode: body.paidNow.mode,
        fromDrawer: body.paidNow.fromDrawer,
        reference: body.paidNow.reference,
        refund: false,
      }, "supplier", supplier.id, { billId, date: billDate, notes: `Paid on bill ${billNumber}`.trim() });
    }
    return bill;
  });

  // Undo a bill entered by mistake: stock goes back out; payments stay (void them separately).
  post("purchase-bills/:id/void", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const bill = await scoped(tx, actor, "purchaseBill", params.id);
    if (bill.voided) fail("This bill is already cancelled.");
    if ((await records(tx, actor.organizationId, "purchaseReturn")).some((r) => r.billId === bill.id))
      fail("Parts on this bill were already returned to the supplier. Return the rest instead of cancelling.", 409);
    const reason = text(body.reason, "reason");
    const withdraw = await supplierWithdrawal(tx, actor);
    for (const line of bill.lines) {
      if (!line.onlineOnly) await withdraw(line.productId, line.binId, line.quantity, line.serials || [], "Purchase bill cancelled", bill.id);
    }
    if (bill.purchaseOrderId) {
      const order = await getRecord(tx, actor.organizationId, "purchaseOrder", bill.purchaseOrderId);
      if (order) {
        for (const line of bill.lines) {
          const ordered = order.lines.find((l: any) => l.productId === line.productId);
          if (ordered) ordered.received = Math.max(0, (ordered.received || 0) - line.quantity);
        }
        order.status = order.lines.every((l: any) => !l.received) ? "open" : "partial";
        await putRecord(tx, actor.organizationId, "purchaseOrder", order, actor.branchId);
      }
    }
    await restoreBillEconomics(tx, actor.organizationId, bill);
    for (const line of bill.lines) {
      if (!line.costHike?.costChangeId) continue;
      const change = await getRecord(tx, actor.organizationId, "costChange", line.costHike.costChangeId);
      if (change?.status === "open")
        await putRecord(tx, actor.organizationId, "costChange", { ...change, status: "cancelled", resolvedAt: now(), resolvedBy: actor.id }, actor.branchId);
    }
    const voided = { ...bill, voided: true, voidReason: reason, voidedAt: now(), voidedBy: actor.id };
    await putRecord(tx, actor.organizationId, "purchaseBill", voided, actor.branchId);
    await audit(tx, actor, "purchase-bill-void", bill.id, reason);
    return voided;
  });

  // ---------- Returns to the supplier ----------
  post("purchase-returns", async (tx, actor, body) => {
    allow(actor, STOCK_ROLES);
    const supplier = await scoped(tx, actor, "supplier", body.supplierId);
    const bill = body.billId ? await scoped(tx, actor, "purchaseBill", body.billId) : null;
    if (bill && bill.supplierId !== supplier.id) fail("That bill is from another supplier.");
    if (bill?.voided) fail("That bill was cancelled.");
    if (!Array.isArray(body.lines) || !body.lines.length) fail("Add the parts being returned.");
    const returnId = id("preturn");
    const lines = [];
    const earlierReturns = bill
      ? (await records(tx, actor.organizationId, "purchaseReturn")).filter((r) => r.billId === bill.id).flatMap((r) => r.lines)
      : [];
    const creditLines = bill ? billCreditLines(bill, earlierReturns) : [];
    let billCreditRemaining = bill ? Math.max(0, bill.total - earlierReturns.reduce((sum, l) => sum + (l.amount ?? l.cost * l.quantity), 0)) : 0;
    const withdraw = await supplierWithdrawal(tx, actor);
    let total = 0;
    for (const input of body.lines) {
      const product = await scoped(tx, actor, "product", input.productId);
      // Online-only goods were never shop stock: the return takes none out.
      const sourceLines = bill?.lines.filter((l: any) => l.productId === product.id) || [];
      // Non-stock credits cannot be verified against a shelf quantity. Link each to
      // the supplier bill for this item, including items since moved to another channel.
      if (!bill && product.onlineOnly) fail("Return this website-only item from its original supplier bill.", 409);
      const nonStock = !!product.onlineOnly || (sourceLines.length > 0 && sourceLines.every((l: any) => l.onlineOnly));
      const bin = nonStock ? null : await scoped(tx, actor, "location", input.binId);
      const quantity = integer(input.quantity, "Quantity", 1, 1000000);
      const statedCost = input.cost == null || input.cost === "" ? null : integer(input.cost, "Unit cost");
      const serials: string[] = Array.isArray(input.serials) ? input.serials.map((s: any) => text(s, "serial")) : [];
      if (product.serialTracked && !nonStock) {
        if (serials.length !== quantity || new Set(serials).size !== quantity)
          fail("Enter one unique serial number per returned unit of " + product.name + ".");
      } else if (serials.length) fail("This return line does not take serial numbers.");
      const base = { productId: product.id, sku: product.sku, name: product.name,
        binId: bin?.id || null, ...(bin ? {} : { onlineOnly: true }) };
      if (bill) {
        if (!sourceLines.length) fail(product.name + " is not on that bill.");
        const selected = input.billLineId;
        const candidates = creditLines.filter(l => l.source.productId === product.id && (!selected || l.source.id === selected));
        if (!candidates.length) fail("That bill line is not for " + product.name + ".");
        if (!selected && !nonStock && new Set(candidates.map(l => [l.source.cost, l.source.taxRate || 0].join("/"))).size > 1) {
          if (candidates.every(l => l.source.id))
            fail("Choose the bill line for " + product.name + "; duplicate lines have different costs.");
          // A recorded serial identifies its original price even on older bills without line IDs.
          if (!serials.length)
            fail("This older bill has differently priced lines without line IDs. The original line cannot be identified.", 409);
        }
        if (serials.some(serial => !candidates.some(l => l.source.serials?.includes(serial))))
          fail("Choose serials supplied on the original bill line.", 409);
        const { allocations, remaining } = allocateReturn(candidates, quantity, serials);
        if (remaining) fail("Only " + (quantity - remaining) + " of " + product.name + " can be returned against the selected bill lines.");
        for (const { line, quantity: units, serials: selectedSerials } of allocations) {
          const next = line.returned + units;
          let amount = Math.min(billCreditRemaining, Math.max(0, line.net - line.credited),
            roundRatio(line.net, next, line.source.quantity) - roundRatio(line.net, line.returned, line.source.quantity));
          if (statedCost != null) amount = Math.min(amount, statedCost * units);
          lines.push({ ...base, quantity: units, amount, cost: roundRatio(amount, 1, units), serials: selectedSerials,
            ...(line.source.id ? { billLineId: line.source.id } : {}) });
          line.returned = next;
          line.credited += amount;
          billCreditRemaining -= amount;
          total += amount;
        }
      } else {
        const cost = statedCost ?? product.cost;
        const amount = cost * quantity;
        if (!Number.isSafeInteger(amount)) fail("The supplier credit amount is too large.");
        lines.push({ ...base, quantity, cost, amount, serials });
        total += amount;
      }
      if (!Number.isSafeInteger(total)) fail("The supplier credit total is too large.");
      if (bin) await withdraw(product.id, bin.id, quantity, serials, "Returned to supplier", returnId);
    }
    const record = {
      id: returnId,
      branchId: actor.branchId,
      supplierId: supplier.id,
      billId: bill?.id || null,
      billNumber: bill?.billNumber || "",
      date: body.date ? day(body.date, "return date") : now().slice(0, 10),
      reason: text(body.reason, "reason", true, 300),
      lines,
      total,
      createdAt: now(),
      userId: actor.id,
    };
    await putRecord(tx, actor.organizationId, "purchaseReturn", record, actor.branchId);
    await audit(tx, actor, "purchase-return", returnId, record.reason, { total });
    return record;
  });

  // ---------- Payments ----------
  post("party-payments", async (tx, actor, body) => {
    const kind = body.partyKind === "customer" ? "customer" : body.partyKind === "supplier" ? "supplier" : fail("Choose a supplier or customer.");
    allow(actor, kind === "supplier" ? ["owner", "manager", "inventory"] : ["owner", "manager", "cashier"]);
    // Paying money back out (or recording money back from a supplier) needs a manager.
    if (body.refund === true) allow(actor, ["owner", "manager"]);
    const party = await scoped(tx, actor, kind, body.partyId);
    return payment(tx, actor, body, kind, party.id);
  });

  post("party-payments/:id/void", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager"]);
    const record = await getRecord(tx, actor.organizationId, "partyPayment", String(params.id));
    if (!record || (record.branchId && record.branchId !== actor.branchId)) fail("Payment not found.", 404);
    if (record.voided || record.reversesId) fail("This payment is already cancelled or is a reversal.", 409);
    const reversalId = "reversal:" + record.id;
    if (await getRecord(tx, actor.organizationId, "partyPayment", reversalId)) fail("This payment has already been reversed.", 409);
    const reason = text(body.reason, "reason");
    if (record.advance && !record.refund && record.partyKind === "customer") {
      const { availableAdvance } = await import("./customer-account.js");
      if (await availableAdvance(tx, actor.organizationId, record.partyId) < record.amount)
        fail("This advance has been applied or refunded. Restore the customer's available advance before reversing the receipt.", 409);
    }
    const fromDrawer = record.mode === "Cash" && !!record.shiftId;
    const shift = fromDrawer ? (await records(tx, actor.organizationId, "shift", actor.branchId))
      .find(s => s.userId === actor.id && !s.closedAt) : null;
    if (fromDrawer && !shift) fail("Open your shift before reversing this drawer payment.", 409);
    const createdAt = now();
    const reversal = { ...record, id: reversalId, reversesId: record.id, shiftId: shift?.id ?? null,
      userId: actor.id, createdAt, date: createdAt.slice(0, 10), direction: record.direction === "in" ? "out" : "in",
      refund: !record.refund, notes: reason, voided: false };
    if (record.onlineOrderId)
      await (await import("./fulfilment.js")).reverseOrderCollection(tx, actor, record);
    await putRecord(tx, actor.organizationId, "partyPayment", reversal, actor.branchId);
    await audit(tx, actor, "payment-void", record.id, reason, { reversalId, shiftId: reversal.shiftId, amount: record.amount });
    return reversal;
  });

  // ---------- Ledgers ----------
  app.get("/api/v1/parties/:kind/:id/ledger", async (request: any) => {
    const actor: Actor = request.actor;
    const kind = request.params.kind === "suppliers" ? "supplier" : request.params.kind === "customers" ? "customer" : fail("Unknown party.", 404);
    allow(actor, kind === "supplier" ? STOCK_ROLES : ["owner", "manager", "cashier"]);
    return db.readSnapshot(async (tx) => {
      const party = await scoped(tx, actor, kind, String(request.params.id));
      const entries = (await partyLedgers(tx, actor.organizationId, kind)).get(party.id) || [];
      return { party, entries, balance: entries.length ? entries[entries.length - 1].balance : 0 };
    });
  });
}
