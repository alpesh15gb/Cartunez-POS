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
import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import { adjust, allow, audit, fail, id, integer, multiline, now, scoped, text, roundRatio, type Actor } from "./domain.js";
import type { Post } from "./routes/types.js";
import { noteCost } from "./cost-changes.js"; // WS-E


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
  for (const payment of await records(db, org, "partyPayment")) {
    if (payment.partyKind !== kind || payment.voided) continue;
    // A refund goes the other way: money given back to a customer, or received back from a supplier.
    add(payment.partyId, {
      date: payment.date,
      at: payment.createdAt,
      type: payment.refund ? "refund" : "payment",
      id: payment.id,
      // WS-B: advances (routes/customers.ts) are labelled as such.
      reference: [payment.advance ? (payment.refund ? "Advance refund" : "Advance") : "", payment.mode, payment.reference].filter(Boolean).join(" · "),
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
      if (core.refundType !== "Credit") continue;
      const invoice = await getRecord(db, org, "invoice", core.invoiceId);
      add(invoice?.customerId, {
        date: String(core.createdAt).slice(0, 10),
        at: core.createdAt,
        type: "sale-return",
        id: core.id,
        reference: `Core deposit on invoice ${invoice?.number || ""}`.trim(),
        note: core.reason || "",
        debit: 0,
        credit: core.total,
      });
    }
    for (const ret of await records(db, org, "return")) {
      if (ret.refundType !== "Credit") continue;
      // WS-B: an exchange credits the account only with what was not set against the new bill.
      const amount = ret.refundTotal ?? ret.total;
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

/** Bill totals. GST (when the bill has it) is added per line on the cost before GST. */
function billTotals(lines: any[], gst: boolean, otherCharges: number, discount: number) {
  let subtotal = 0,
    tax = 0;
  for (const line of lines) {
    line.amount = line.quantity * line.cost;
    line.tax = gst ? roundRatio(line.amount * line.taxRate, 1, 10000) : 0;
    subtotal += line.amount;
    tax += line.tax;
  }
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
  const shift = mode === "Cash" && body.fromDrawer !== false
    ? (await records(db, actor.organizationId, "shift", actor.branchId)).find((s) => s.userId === actor.id && !s.closedAt)
    : null;
  const record = {
    id: id("payment"),
    shiftId: shift?.id || null,
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
      const bin = await scoped(tx, actor, "location", input.binId);
      if (bin.kind !== "sellable") fail("Put purchased stock into a sellable bin.");
      if (order) {
        const ordered = order.lines.find((l: any) => l.productId === product.id);
        const outstanding = ordered ? ordered.quantity - (ordered.received || 0) : null;
        const earlier = body.lines.slice(0, body.lines.indexOf(input)).filter((l: any) => l.productId === product.id)
          .reduce((n: number, l: any) => n + Number(l.quantity || 0), 0);
        if (outstanding != null && Number(input.quantity) + earlier > outstanding)
          fail(`Only ${Math.max(outstanding - earlier, 0)} of ${product.name} are still due on that purchase order (the rest was already received).`);
      }
      const line = {
        productId: product.id,
        sku: product.sku,
        name: product.name,
        quantity: integer(input.quantity, "Quantity", 1, 1000000),
        cost: integer(input.cost, "Unit cost"),
        taxRate: gst ? integer(input.taxRate ?? 0, "GST rate", 0, 4000) : 0,
        binId: bin.id,
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
    // Freight and discount are spread over the units by value, so stock cost is what the part really cost.
    const spread = otherCharges - discount;
    let allocated = 0,
      cumulative = 0;
    for (const line of lines) {
      const product = await scoped(tx, actor, "product", line.productId);
      cumulative += line.amount;
      const next = totals.subtotal ? roundRatio(spread, cumulative, totals.subtotal) : 0;
      const share = next - allocated;
      allocated = next;
      // On a GST bill the GST is claimed back, so it is not part of the stock cost.
      // On a bill without GST, what was paid is the cost.
      line.landedCost = Math.max(0, line.cost + roundRatio(share, 1, line.quantity));
      // WS-E: flag a supplier cost hike against the last purchase cost.
      const hike = await noteCost(tx, actor, product, line.cost, {
        kind: "bill", id: billId, label: billNumber ? `Bill ${billNumber}` : "Purchase bill", supplierId: supplier.id,
      });
      if (hike) line.costHike = hike;
      product.cost = line.landedCost;
      if (line.mrp != null) product.retailPrice = line.mrp;
      await putRecord(tx, actor.organizationId, "product", product);
      for (const serial of line.serials) {
        const serialId = product.id + ":" + serial;
        if (await getRecord(tx, actor.organizationId, "serial", serialId)) fail(`Serial ${serial} already exists.`);
        await putRecord(tx, actor.organizationId, "serial",
          { id: serialId, branchId: actor.branchId, productId: product.id, serial, binId: line.binId, status: "available" }, actor.branchId);
      }
      await adjust(tx, actor, product.id, line.binId, line.quantity, "Purchase bill", billId);
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
    if (body.paidNow && Number(body.paidNow.amount) > 0) {
      if (Number(body.paidNow.amount) > totals.total) fail("The amount paid now is more than the bill.");
      await payment(tx, actor, { ...body.paidNow, date: billDate, notes: `Paid on bill ${billNumber}`.trim() }, "supplier", supplier.id, { billId });
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
    for (const line of bill.lines) {
      await adjust(tx, actor, line.productId, line.binId, -line.quantity, "Purchase bill cancelled", bill.id);
      for (const serial of line.serials || []) {
        const serialId = line.productId + ":" + serial;
        const record = await getRecord(tx, actor.organizationId, "serial", serialId);
        if (record && record.status !== "available") fail(`Serial ${serial} has already been sold.`, 409);
        await tx.query("DELETE FROM records WHERE organization_id=$1 AND kind='serial' AND id=$2", [actor.organizationId, serialId]);
      }
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
    const inRequest = new Map<string, number>();
    const earlierReturns = bill
      ? (await records(tx, actor.organizationId, "purchaseReturn")).filter((r) => r.billId === bill.id).flatMap((r) => r.lines)
      : [];
    let total = 0;
    for (const input of body.lines) {
      const product = await scoped(tx, actor, "product", input.productId);
      const bin = await scoped(tx, actor, "location", input.binId);
      const quantity = integer(input.quantity, "Quantity", 1, 1000000);
      let cost = integer(input.cost ?? product.cost, "Unit cost");
      if (bill) {
        const billLines = bill.lines.filter((l: any) => l.productId === product.id);
        if (!billLines.length) fail(`${product.name} is not on that bill.`);
        const billed = billLines.reduce((n: number, l: any) => n + l.quantity, 0);
        const returned = earlierReturns.filter((l: any) => l.productId === product.id).reduce((n: number, l: any) => n + l.quantity, 0)
          + (inRequest.get(product.id) || 0);
        if (quantity > billed - returned) fail(`Only ${billed - returned} of ${product.name} can be returned against this bill.`);
        // Credit what the supplier charged per unit on that bill (GST included on a GST bill), never more.
        const line = billLines[0];
        const charged = line.cost + (bill.gst ? roundRatio(line.cost * (line.taxRate || 0), 1, 10000) : 0);
        cost = input.cost == null || input.cost === "" ? charged : Math.min(cost, charged);
      }
      inRequest.set(product.id, (inRequest.get(product.id) || 0) + quantity);
      const serials: string[] = [];
      if (product.serialTracked) {
        const list = Array.isArray(input.serials) ? input.serials.map((s: any) => text(s, "serial")) : [];
        if (list.length !== quantity || new Set(list).size !== quantity) fail(`Enter the serial number of each ${product.name} being returned.`);
        for (const serial of list) {
          const serialId = product.id + ":" + serial;
          const record = await getRecord(tx, actor.organizationId, "serial", serialId);
          if (!record || record.status !== "available" || record.binId !== bin.id) fail(`Serial ${serial} is not in stock in that bin.`);
          await tx.query("DELETE FROM records WHERE organization_id=$1 AND kind='serial' AND id=$2", [actor.organizationId, serialId]);
          serials.push(serial);
        }
      }
      await adjust(tx, actor, product.id, bin.id, -quantity, "Returned to supplier", returnId);
      lines.push({ productId: product.id, sku: product.sku, name: product.name, quantity, cost, binId: bin.id, amount: quantity * cost, serials });
      total += quantity * cost;
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
    if (record!.voided) fail("This payment is already cancelled.");
    const reason = text(body.reason, "reason");
    const voided = { ...record, voided: true, voidReason: reason, voidedAt: now(), voidedBy: actor.id };
    await putRecord(tx, actor.organizationId, "partyPayment", voided, record!.branchId || "");
    await audit(tx, actor, "payment-void", record!.id, reason);
    return voided;
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
