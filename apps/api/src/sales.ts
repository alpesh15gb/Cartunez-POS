import type { Database, RecordData } from "./db.js";
import { getRecord, putRecord, records } from "./db.js";
import {
  type Actor,
  allow,
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

export async function finalizeSale(
  db: Database,
  actor: Actor,
  body: any,
  reconcile = false,
) {
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
  const used = new Set<string>();
  const lines: any[] = [];
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
  const inclusive = profile.taxMode === "inclusive";
  let subtotal = 0,
    coreTotal = 0;
  let requiresFitmentApproval = false;
  for (const input of body.lines) {
    const currentProduct = await scoped(db, actor, "product", input.productId);
    const product = body.offline
      ? catalog.products.find((entry: any) => entry.id === input.productId)
      : currentProduct;
    if (!product)
      fail("Part was absent from the authorized offline catalog.", 409);
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
      requiresFitmentApproval = true;
    }
    if (product.type !== "service") {
      const bin = await scoped(db, actor, "location", input.binId);
      if (bin.kind !== "sellable") fail("Sale picks must use a sellable bin.");
      const available =
        stock.find(
          (entry) =>
            entry.productId === product.id && entry.binId === input.binId,
        )?.available || 0;
      const ownHold = (hold?.cart.lines || [])
        .filter(
          (entry: any) =>
            entry.productId === product.id && entry.binId === input.binId,
        )
        .reduce((sum: number, entry: any) => sum + entry.qty, 0);
      if (!reconcile && available + ownHold < qty)
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
    subtotal += lineSubtotal;
    coreTotal += integer((product.coreCharge || 0) * qty, "Line core charge");
    integer(product.cost * qty, "Line cost");
    lines.push({
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
    });
  }
  integer(subtotal, "Invoice subtotal");
  integer(coreTotal, "Invoice core charges");
  const discount = integer(body.discount ?? 0, "Discount", 0, subtotal);
  if (requiresFitmentApproval)
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
    line.discount = next - allocated;
    allocated = next;
    line.tax = inclusive
      ? line.subtotal -
        line.discount -
        roundRatio(line.subtotal - line.discount, 10000, 10000 + line.taxRate)
      : roundRatio(line.subtotal - line.discount, line.taxRate, 10000);
    line.taxMode = profile.taxMode;
    line.taxComponents = splitTax(
      line.tax,
      line.taxRate,
      profile,
      placeOfSupply,
    );
    line.total =
      line.subtotal -
      line.discount +
      (inclusive ? 0 : line.tax) +
      line.coreCharge * line.qty;
    tax += line.tax;
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
    line.rounding = Math.max(remainingRounding, -(line.total - line.coreCharge * line.qty));
    line.total += line.rounding;
    remainingRounding -= line.rounding;
  }
  if (remainingRounding)
    fail("Invoice rounding would reduce the refundable core deposit. Use a smaller rounding increment.", 409);
  if (
    !Array.isArray(body.tenders) ||
    !body.tenders.length ||
    body.tenders.length > 10
  )
    fail("Choose a payment method.");
  const tenders = body.tenders.map((tender: any) => ({
    type: text(tender.type, "tender type"),
    amount: integer(tender.amount, "Tender amount"),
    confirmed: tender.confirmed === true,
    reference: text(tender.reference || "", "payment reference", false, 200),
  }));
  if (
    tenders.some(
      (tender: any) =>
        !(currentSettings.tenderTypes || ["Cash", "Card", "UPI"]).includes(
          tender.type,
        ),
    )
  )
    fail("This payment type is disabled in Settings.");
  if (
    tenders.some(
      (tender: any) =>
        tender.type !== "Cash" && tender.confirmed && !tender.reference,
    )
  )
    fail("Record the external payment confirmation reference.");
  if (
    tenders.some(
      (tender: any) => !["Cash", "Card", "UPI"].includes(tender.type),
    )
  )
    fail("Unsupported tender type.");
  if (
    tenders.some((tender: any) => tender.type !== "Cash" && !tender.confirmed)
  )
    fail(
      "Provider-confirmed payments must remain pending until confirmation.",
      409,
    );
  const paid = tenders.reduce(
    (sum: number, tender: any) => sum + tender.amount,
    0,
  );
  const cash = tenders
    .filter((tender: any) => tender.type === "Cash")
    .reduce((sum: number, tender: any) => sum + tender.amount, 0);
  if (paid < total || paid - total > cash)
    fail("Payments must cover the total. Change can only come from cash.");
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
    if (tenders.some((tender: any) => !device.tenders.includes(tender.type)))
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
  const invoice = {
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
    subtotal,
    discount,
    discountReason: body.discountReason || "",
    tax,
    taxComponents: taxTotals(lines),
    coreTotal,
    rounding,
    total,
    tenders,
    change: paid - total,
    cost: lines.reduce((sum, line) => sum + line.cost * line.qty, 0),
  };
  if (body.customerId) await scoped(db, actor, "customer", body.customerId);
  for (const line of lines) {
    if (line.type !== "service")
      await adjust(
        db,
        actor,
        line.productId,
        line.binId,
        -line.qty,
        "Sale",
        invoice.id,
        reconcile,
      );
    for (const serial of line.serials)
      await putRecord(
        db,
        actor.organizationId,
        "serial",
        {
          id: line.productId + ":" + serial,
          branchId: actor.branchId,
          productId: line.productId,
          serial,
          binId: line.binId,
          status: "sold",
          invoiceId: invoice.id,
        },
        actor.branchId,
      );
  }
  if (hold)
    await db.query(
      "DELETE FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3",
      [actor.organizationId, "hold", hold.id],
    );
  await putRecord(db, actor.organizationId, "invoice", invoice, actor.branchId);
  await audit(
    db,
    actor,
    "sale",
    invoice.id,
    body.discountReason || "Checkout",
    { total, override: requiresFitmentApproval, reconciled: reconcile },
  );
  return invoice;
}

export async function returnInvoice(
  db: Database,
  actor: Actor,
  invoiceId: string,
  body: any,
  voided = false,
) {
  allow(actor, ["owner", "manager", "cashier"]);
  await approved(db, actor, "return", body.approvalId, body.transactionId);
  const invoice = await scoped(db, actor, "invoice", invoiceId);
  const shift = (
    await records(db, actor.organizationId, "shift", actor.branchId)
  ).find((item) => item.userId === actor.id && !item.closedAt);
  if (!shift) fail("Open your shift before recording a refund.", 409);
  const previous = (
    await records(db, actor.organizationId, "return", actor.branchId)
  ).filter((item) => item.invoiceId === invoiceId);
  text(body.reason, "return reason");
  if (!["sellable", "damaged", "warranty"].includes(body.condition))
    fail("Choose return condition.");
  if (!Array.isArray(body.lines) || !body.lines.length)
    fail("Select return lines.");
  const lines: any[] = [];
  const used = new Set<string>();
  for (const input of body.lines) {
    const original = invoice.lines.find((line: any) =>
      input.lineId
        ? line.id === input.lineId
        : line.productId === input.productId,
    );
    if (!original) fail("Select an original invoice line.");
    if (used.has(original.id)) fail("Combine duplicate return lines.");
    used.add(original.id);
    const returned = previous
      .flatMap((item) => item.lines)
      .filter((item) => item.lineId === original.id)
      .reduce((sum, line) => sum + line.quantity, 0);
    const quantity = integer(
      input.quantity,
      "Return quantity",
      1,
      original.qty - returned,
    );
    const bin =
      original.type === "service"
        ? null
        : await scoped(db, actor, "location", input.binId);
    if (bin && bin.kind !== body.condition)
      fail("Return destination must match the condition.");
    const product = await scoped(db, actor, "product", original.productId);
    const serials = input.serials || [];
    if (original.serials?.length) {
      if (
        !Array.isArray(serials) ||
        serials.length !== quantity ||
        new Set(serials).size !== quantity
      )
        fail("Return one serial number for each unit.");
      for (const serial of serials) {
        const item = await scoped(
          db,
          actor,
          "serial",
          product.id + ":" + serial,
        );
        if (
          !original.serials.includes(serial) ||
          item.status !== "sold" ||
          item.invoiceId !== invoiceId
        )
          fail(
            "Serial was not sold on this invoice or has already been returned.",
          );
        await putRecord(
          db,
          actor.organizationId,
          "serial",
          {
            ...item,
            status:
              body.condition === "sellable" ? "available" : body.condition,
            binId: bin!.id,
            invoiceId: null,
          },
          actor.branchId,
        );
      }
    }
    const proportion = (value: number) =>
      roundRatio(value, returned + quantity, original.qty) -
      roundRatio(value, returned, original.qty);
    const subtotal = proportion(original.subtotal),
      discount = proportion(original.discount),
      tax = proportion(original.tax);
    // Allocate component refunds from cumulative tax, preserving both each credit's tax
    // total and each original component across any series of partial returns.
    let componentCumulative = 0,
      componentAllocatedBefore = 0,
      componentAllocatedAfter = 0;
    const taxBefore = roundRatio(original.tax, returned, original.qty);
    const taxAfter = roundRatio(
      original.tax,
      returned + quantity,
      original.qty,
    );
    const taxComponents = (original.taxComponents || []).map(
      (component: any) => {
        componentCumulative += component.amount;
        const before = original.tax
          ? roundRatio(taxBefore, componentCumulative, original.tax)
          : 0;
        const after = original.tax
          ? roundRatio(taxAfter, componentCumulative, original.tax)
          : 0;
        const amount =
          after - componentAllocatedAfter - before + componentAllocatedBefore;
        componentAllocatedBefore = before;
        componentAllocatedAfter = after;
        return { ...component, amount };
      },
    );
    // Allocate the refundable amount cumulatively so rounding components separately
    // cannot produce a negative credit or pay the last unit twice.
    const priorRefund = previous.flatMap((item) => item.lines)
      .filter((line) => line.lineId === original.id)
      .reduce((sum, line) => sum + line.total, 0);
    const refundable = original.total - (original.coreCharge || 0) * original.qty;
    const total = Math.max(0, roundRatio(refundable, returned + quantity, original.qty) - priorRefund);
    const rounding = total - (subtotal - discount + (invoice.taxMode === "inclusive" ? 0 : tax));
    lines.push({
      lineId: original.id,
      productId: original.productId,
      sku: original.sku,
      name: original.name,
      hsnSac: original.hsnSac || "",
      unit: original.unit,
      taxRate: original.taxRate,
      quantity,
      binId: bin?.id || null,
      type: original.type,
      serials,
      subtotal,
      discount,
      tax,
      taxComponents,
      rounding,
      taxMode: invoice.taxMode || "exclusive",
      total,
      cost: original.cost * quantity,
    });
  }
  const total = lines.reduce((sum, line) => sum + line.total, 0);
  const settings = (await getRecord(
    db,
    actor.organizationId,
    "settings",
    "settings",
  ))!;
  const creditNumber = settings.nextCreditNote || 1;
  settings.nextCreditNote = creditNumber + 1;
  await putRecord(db, actor.organizationId, "settings", settings);
  if (!["Cash", "Card", "UPI"].includes(body.refundType || "Cash"))
    fail("Choose a supported refund method.");
  const receipt = {
    ...invoiceProfile(
      invoice,
      invoice.branch || { id: invoice.branchId, name: "" },
    ),
    customer: invoice.customer || null,
    placeOfSupply: invoice.placeOfSupply || "",
    id: id("return"),
    number: documentNumber(
      `${settings.creditNotePrefix || "CR"}-${actor.branchId.toUpperCase()}-${creditNumber}`,
      invoice.taxScheme || "general",
    ),
    invoiceNumber: invoice.number,
    invoiceDate: invoice.createdAt,
    branchId: actor.branchId,
    invoiceId,
    transactionId: body.transactionId,
    userId: actor.id,
    shiftId: shift.id,
    createdAt: now(),
    reason: body.reason,
    condition: body.condition,
    refundType: body.refundType || "Cash",
    total,
    tax: lines.reduce((sum, line) => sum + line.tax, 0),
    taxComponents: taxTotals(lines),
    lines,
    voided,
  };
  for (const line of lines) {
    if (line.type !== "service")
      await adjust(
        db,
        actor,
        line.productId,
        line.binId,
        line.quantity,
        voided ? "Invoice void" : "Sales return",
        receipt.id,
      );
  }
  await putRecord(db, actor.organizationId, "return", receipt, actor.branchId);
  await audit(
    db,
    actor,
    voided ? "invoice-void" : "return",
    invoiceId,
    body.reason,
    { returnId: receipt.id, total },
  );
  return receipt;
}
