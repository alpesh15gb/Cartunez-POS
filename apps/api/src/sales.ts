import type { Database } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import {
  type Actor,
  allow,
  holdReserves,
  integer,
  text,
  fail,
  now,
  id,
  roundRatio,
  fitment,
  scoped,
  approved,
  adjust,
  audit,
  inventory,
} from "./domain.js";
import {
  invoiceProfile,
  gstProfile,
  gstState,
  gstRegistration,
  documentNumber,
  splitTax,
  taxTotals,
} from "./settings.js";
import type { InvoiceDraft, SaleContext, SaleLine, SaleTender } from "./sale-types.js";
import { runStage, runValidateLine } from "./sale-pipeline.js";

/**
 * Checkout. Runs in explicit stages; the extension points between them are the
 * hooks in sale-pipeline.ts (see SaleHook in sale-types.ts):
 *   prepare -> lines (+validateLine) -> expandLines -> totals -> tenders
 *   (+validateTenders) -> numbering -> beforePersist -> write -> afterPersist
 */
/**
 * Marks a checkout built on the server by jobs/:id/invoice. Request JSON cannot
 * carry a symbol, so only that route may bill a job card's parked reservation.
 */
export const JOB_INVOICE = Symbol("job-invoice");

export async function finalizeSale(
  db: Database,
  actor: Actor,
  body: any,
  reconcile = false,
) {
  const ctx = await prepareSale(db, actor, body, reconcile);
  await buildLines(ctx);
  await runStage("expandLines", ctx);
  await computeTotals(ctx);
  normaliseTenders(ctx);
  await runStage("validateTenders", ctx);
  checkTenderCoverage(ctx);
  const number = await allocateInvoiceNumber(ctx);
  ctx.invoice = draftInvoice(ctx, number);
  await runStage("beforePersist", ctx);
  await putRecord(db, actor.organizationId, "invoice", ctx.invoice, actor.branchId);
  await runStage("afterPersist", ctx);
  return ctx.invoice;
}

/** Permissions, shift, settings, offline snapshot, invoice profile, customer, place of supply. */
async function prepareSale(
  db: Database,
  actor: Actor,
  body: any,
  reconcile: boolean,
): Promise<SaleContext> {
  allow(actor, ["owner", "manager", "cashier"]);
  if (body.offline !== undefined && typeof body.offline !== "boolean")
    fail("Offline mode must be a boolean.");
  if (
    body.priceLevel !== undefined &&
    !["retail", "wholesale"].includes(body.priceLevel)
  )
    fail("Choose a supported price level.");
  const currentSettings = (await getRecord(
    db,
    actor.organizationId,
    "settings",
    "settings",
  ))!;
  // Selling when the system shows no stock (stock goes negative until the
  // purchase is entered). On unless switched off in Settings › Modules.
  const sellBeyondStock = currentSettings.features?.negativeStock !== false;
  const shift = await scoped(db, actor, "shift", body.shiftId);
  if (
    shift.closedAt ||
    (shift.userId !== actor.id && !["owner", "manager"].includes(actor.role))
  )
    fail("Open your shift before checkout.", 409);
  if (
    !Array.isArray(body.lines) ||
    !body.lines.length ||
    body.lines.length > 200
  )
    fail("Add between one and 200 sale lines.");
  const stock = await inventory(db, actor);
  const hold = body.holdId
    ? await scoped(db, actor, "hold", body.holdId)
    : undefined;
  // Integration: a job card's stock reservation is billed only from the job (jobs/:id/invoice).
  if (hold?.jobId && !body[JOB_INVOICE])
    fail("These parts are reserved for a job card. Bill them from the job card.", 409);
  let catalog: any;
  if (body.offline) {
    catalog = await getRecord(
      db,
      actor.organizationId,
      "catalogSnapshot",
      body.catalogRevision,
    );
    if (!catalog || !catalog.settings || catalog.branchId !== actor.branchId)
      fail("The offline catalog authorization is unavailable.", 409);
  }
  const settings = body.offline ? catalog.settings : currentSettings;
  if (settings.currency !== currentSettings.currency)
    fail(
      "The offline snapshot uses a different accounting currency. Manager review is required.",
      409,
    );
  const branch = body.offline
    ? catalog.branch
    : await getRecord(db, actor.organizationId, "branch", actor.branchId);
  const profile = invoiceProfile(settings, branch!);
  if (
    process.env.NODE_ENV === "production" &&
    (!profile.business.legalName || !profile.business.address)
  )
    fail(
      "Complete the legal business name and address in Settings before issuing invoices.",
      409,
    );
  const customer = body.customerId
    ? body.offline
      ? catalog.customers?.find((entry: any) => entry.id === body.customerId)
      : await scoped(db, actor, "customer", body.customerId)
    : null;
  if (body.customerId && !customer)
    fail("Customer was absent from the authorized offline snapshot.", 409);
  let placeOfSupply = text(
    body.placeOfSupply || "",
    "place of supply",
    false,
    200,
  );
  gstProfile(profile);
  if (profile.taxScheme === "india-gst") {
    placeOfSupply = gstState(
      placeOfSupply || customer?.stateCode || "",
      "place-of-supply state code",
    );
    if (customer?.taxRegistrationId) {
      gstRegistration(
        customer.taxRegistrationId,
        gstState(customer.stateCode, "customer state code"),
        "customer GSTIN",
      );
      if (!customer.address) fail("Enter the registered customer address.");
    }
  }
  return {
    db,
    actor,
    body,
    reconcile,
    currentSettings,
    settings,
    branch,
    profile,
    shift,
    hold,
    catalog,
    stock,
    sellBeyondStock,
    customer,
    placeOfSupply,
    lines: [],
    tenders: [],
    requiresFitmentApproval: false,
    subtotal: 0,
    coreTotal: 0,
    discount: 0,
    tax: 0,
    rounding: 0,
    total: 0,
    state: {},
  };
}

/** Prices each input line, checks stock, serials and fitment, then runs validateLine hooks. */
async function buildLines(ctx: SaleContext) {
  const { db, actor, body, profile, catalog, stock, hold, reconcile, sellBeyondStock } = ctx;
  const used = new Set<string>();
  for (const input of body.lines) {
    // WS-B: exchange return lines are settled by hooks/exchange.ts, not sold.
    if (input?.kind === "returnRef") continue;
    const currentProduct = await scoped(db, actor, "product", input.productId);
    const product = body.offline
      ? catalog.products.find((entry: any) => entry.id === input.productId)
      : currentProduct;
    if (!product)
      fail("Part was absent from the authorized offline catalog.", 409);
    if (currentProduct.salesStopped || product.salesStopped)
      fail("New sales are stopped for " + product.sku + "." +
        (body.offline ? " Manager review of this offline claim is required." : ""), 409);
    if (profile.taxScheme === "india-gst") {
      if (!/^(\d{4}|\d{6}|\d{8})$/.test(product.hsnSac || ""))
        fail(
          `Enter a 4, 6, or 8 digit HSN/SAC classification for ${product.sku}.`,
        );
      if (product.coreCharge)
        fail(
          "India GST mode does not support refundable core deposits without a separately configured tax treatment.",
        );
    }
    if ((!product.serialTracked || product.type === "service") && input.serials?.length)
      fail("Only serial-tracked stock accepts serial numbers.");
    const qty = integer(input.qty, "Quantity", 1, 9999);
    const key = product.id + "|" + input.binId;
    if (used.has(key)) fail("Combine duplicate product and bin lines.");
    used.add(key);
    const decision = fitment(
      product,
      body.vehicle,
      body.offline ? String(body.occurredAt).slice(0, 10) : undefined,
    );
    if (["incompatible", "unverified"].includes(decision.status)) {
      text(input.overrideReason, "fitment override reason");
      ctx.requiresFitmentApproval = true;
    }
    if (product.type !== "service") {
      const bin = await scoped(db, actor, "location", input.binId);
      if (bin.kind !== "sellable") fail("Sale picks must use a sellable bin.");
      const available =
        stock.find(
          (entry) =>
            entry.productId === product.id && entry.binId === input.binId,
        )?.available || 0;
      // An expired hold no longer reserves stock, so it adds nothing back.
      const ownHold = (hold && holdReserves(hold) ? hold.cart.lines || [] : [])
        .filter(
          (entry: any) =>
            entry.productId === product.id && entry.binId === input.binId,
        )
        .reduce((sum: number, entry: any) => sum + entry.qty, 0);
      if (!reconcile && !(sellBeyondStock && !product.serialTracked) && available + ownHold < qty)
        fail(`Insufficient stock for ${product.sku} in the selected bin.`, 409);
      if (product.serialTracked) {
        if (
          !Array.isArray(input.serials) ||
          input.serials.length !== qty ||
          new Set(input.serials).size !== qty
        )
          fail("Scan one unique serial number per unit.");
        for (const serial of input.serials) {
          const item = await scoped(
            db,
            actor,
            "serial",
            product.id + ":" + serial,
          );
          if (item.status !== "available" || item.binId !== input.binId)
            fail("Serial is unavailable in the picked bin.", 409);
        }
      }
    }
    const price =
      body.priceLevel === "wholesale"
        ? product.wholesalePrice
        : product.retailPrice;
    const lineSubtotal = integer(price * qty, "Line amount");
    integer((product.coreCharge || 0) * qty, "Line core charge");
    integer(product.cost * qty, "Line cost");
    const line: SaleLine = {
      id: id("line"),
      productId: product.id,
      sku: product.sku,
      name: product.name,
      hsnSac: product.hsnSac || "",
      unit: product.unit,
      category: product.category,
      supplierId: product.supplierId,
      qty,
      binId: input.binId,
      serials: input.serials || [],
      unitPrice: price,
      cost: product.cost,
      taxRate: product.taxRate,
      coreCharge: product.coreCharge || 0,
      subtotal: lineSubtotal,
      fitment: decision,
      overrideReason: input.overrideReason || "",
      type: product.type,
    };
    await runValidateLine(ctx, input, line);
    ctx.lines.push(line);
  }
}

/** Discount approval, per-line discount/tax allocation, rounding and the quoted-total check. */
async function computeTotals(ctx: SaleContext) {
  const { db, actor, body, lines, profile, settings, currentSettings, placeOfSupply } = ctx;
  const inclusive = profile.taxMode === "inclusive";
  const subtotal = lines.reduce((sum, line) => sum + line.subtotal, 0);
  const coreTotal = lines.reduce(
    (sum, line) => sum + (line.coreCharge || 0) * line.qty,
    0,
  );
  integer(subtotal, "Invoice subtotal");
  integer(coreTotal, "Invoice core charges");
  const discount = integer(body.discount ?? 0, "Discount", 0, subtotal);
  if (ctx.requiresFitmentApproval)
    await approved(db, actor, "fitment", body.approvalId, body.transactionId);
  if (discount > currentSettings.cashierDiscountLimit) {
    text(body.discountReason, "discount reason");
    await approved(
      db,
      actor,
      "discount",
      body.discountApprovalId || body.approvalId,
      body.transactionId,
    );
  }
  let allocated = 0,
    cumulative = 0,
    tax = 0;
  for (const line of lines) {
    cumulative += line.subtotal;
    const next = subtotal ? roundRatio(discount, cumulative, subtotal) : 0;
    const lineDiscount = next - allocated;
    line.discount = lineDiscount;
    allocated = next;
    const lineTax = inclusive
      ? line.subtotal -
        lineDiscount -
        roundRatio(line.subtotal - lineDiscount, 10000, 10000 + line.taxRate)
      : roundRatio(line.subtotal - lineDiscount, line.taxRate, 10000);
    line.tax = lineTax;
    line.taxMode = profile.taxMode;
    line.taxComponents = splitTax(
      lineTax,
      line.taxRate,
      profile,
      placeOfSupply,
    );
    line.total =
      line.subtotal -
      lineDiscount +
      (inclusive ? 0 : lineTax) +
      line.coreCharge * line.qty;
    tax += lineTax;
  }
  const unrounded = subtotal - discount + (inclusive ? 0 : tax) + coreTotal;
  const total =
    roundRatio(unrounded, 1, settings.roundingIncrement) *
    settings.roundingIncrement;
  const rounding = total - unrounded;
  integer(total, "Invoice total");
  if (body.expectedTotal !== undefined && integer(body.expectedTotal, "Quoted total") !== total)
    fail("The bill total changed. Refresh the register and review the amount before taking payment.", 409);
  let remainingRounding = rounding;
  for (const line of [...lines].reverse()) {
    if (!remainingRounding) break;
    const lineTotal = line.total!;
    line.rounding = Math.max(remainingRounding, -(lineTotal - line.coreCharge * line.qty));
    line.total = lineTotal + line.rounding;
    remainingRounding -= line.rounding;
  }
  if (remainingRounding)
    fail("Invoice rounding would reduce the refundable core deposit. Use a smaller rounding increment.", 409);
  Object.assign(ctx, { subtotal, coreTotal, discount, tax, rounding, total });
}

function normaliseTenders(ctx: SaleContext) {
  const { body } = ctx;
  if (
    !Array.isArray(body.tenders) ||
    !body.tenders.length ||
    body.tenders.length > 10
  )
    fail("Choose a payment method.");
  ctx.tenders = body.tenders.map((tender: any): SaleTender => ({
    type: text(tender.type, "tender type"),
    amount: integer(tender.amount, "Tender amount"),
    confirmed: tender.confirmed === true,
    reference: text(tender.reference || "", "payment reference", false, 200),
  }));
}

function checkTenderCoverage(ctx: SaleContext) {
  const paid = ctx.tenders.reduce((sum, tender) => sum + tender.amount, 0);
  const cash = ctx.tenders
    .filter((tender) => tender.type === "Cash")
    .reduce((sum, tender) => sum + tender.amount, 0);
  if (paid < ctx.total || paid - ctx.total > cash)
    fail("Payments must cover the total. Change can only come from cash.");
}

/** Offline: validates the device's reserved range. Online: next free invoice number. */
async function allocateInvoiceNumber(ctx: SaleContext) {
  const { db, actor, body, settings, tenders } = ctx;
  let number: number;
  if (body.offline) {
    const device = await scoped(db, actor, "device", body.deviceId);
    const occurredAt = new Date(body.occurredAt).getTime();
    if (
      !device.offlineAllowed ||
      !Number.isFinite(occurredAt) ||
      occurredAt > new Date(device.offlineUntil).getTime() ||
      // Permit small client/server clock skew at enrollment, never after expiry.
      occurredAt < new Date(device.enrolledAt).getTime() - 60000 ||
      occurredAt > Date.now() + 300000
    )
      fail("Offline authorization was invalid at the sale time.", 403);
    if (tenders.some((tender) => !device.tenders.includes(tender.type)))
      fail("Tender is unavailable offline.", 403);
    number = integer(
      body.invoiceNumber,
      "Device invoice number",
      device.rangeStart,
      device.rangeEnd,
    );
    if (
      (await records(db, actor.organizationId, "invoice", actor.branchId)).some(
        (invoice) => invoice.invoiceNumber === number,
      )
    )
      fail("Invoice number already used.", 409);
  } else {
    const devices = await records(db, actor.organizationId, "device");
    while (
      devices.some(
        (device) =>
          settings.nextInvoice >= device.rangeStart &&
          settings.nextInvoice <= device.rangeEnd,
      )
    )
      settings.nextInvoice =
        devices.find(
          (device) =>
            settings.nextInvoice >= device.rangeStart &&
            settings.nextInvoice <= device.rangeEnd,
        )!.rangeEnd + 1;
    number = settings.nextInvoice++;
    await putRecord(db, actor.organizationId, "settings", settings);
  }
  return number;
}

function draftInvoice(ctx: SaleContext, number: number): InvoiceDraft {
  const { actor, body, settings, profile, shift, customer, placeOfSupply, lines, tenders } = ctx;
  const paid = tenders.reduce((sum, tender) => sum + tender.amount, 0);
  return {
    ...profile,
    id: id("invoice"),
    branchId: actor.branchId,
    transactionId: body.transactionId,
    number: documentNumber(
      `${settings.invoicePrefix}-${actor.branchId.toUpperCase()}-${number}`,
      profile.taxScheme,
    ),
    invoiceNumber: number,
    currency: settings.currency,
    createdAt: body.offline ? body.occurredAt : now(),
    finalizedAt: now(),
    cashierId: actor.id,
    shiftId: shift.id,
    deviceId: body.deviceId || null,
    offline: !!body.offline,
    customerId: body.customerId || null,
    customer,
    placeOfSupply,
    vehicle: body.vehicle || null,
    priceLevel: body.priceLevel || "retail",
    lines,
    subtotal: ctx.subtotal,
    discount: ctx.discount,
    discountReason: body.discountReason || "",
    tax: ctx.tax,
    taxComponents: taxTotals(lines),
    coreTotal: ctx.coreTotal,
    rounding: ctx.rounding,
    total: ctx.total,
    tenders,
    change: paid - ctx.total,
    cost: lines.reduce((sum, line) => sum + line.cost * line.qty, 0),
  };
}

// WS-B: returns and credit notes moved to returns.ts; re-exported for existing callers.
export { returnInvoice } from "./returns.js";
