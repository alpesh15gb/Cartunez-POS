import { reorderSuggestions } from "./replenishment.js";
import { shiftCashSummaries } from "./shift-cash.js";
import { refundBy } from "./returns.js";
import type { Database } from "./db.js";
import { records, getRecord } from "./db.js";
import { type Actor, allow, fail, inventory, now } from "./domain.js";

export async function report(
  db: Database,
  actor: Actor,
  name: string,
  filters: any,
) {
  allow(actor, ["owner", "manager", "inventory"]);
  if (
    actor.role === "inventory" &&
    ![
      "valuation",
      "stock-by-bin",
      "stock-movement",
      "low-stock",
      "fast-moving",
      "slow-moving",
      "aging",
      "purchase-receipts",
      "warranty",
    ].includes(name)
  )
    fail("This report requires manager access.", 403);
  if (filters.branchId && filters.branchId !== actor.branchId)
    fail("Switch to the requested branch before reporting.", 403);
  for (const key of ["dateFrom", "dateTo"]) {
    const value = filters[key];
    if (value === undefined) continue;
    const time = new Date(`${value}T00:00:00Z`);
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) ||
        !Number.isFinite(time.getTime()) || time.toISOString().slice(0, 10) !== value)
      fail("Use a valid date in YYYY-MM-DD format.");
  }
  if (filters.dateFrom && filters.dateTo && filters.dateFrom > filters.dateTo)
    fail("The start date must be on or before the end date.");
  const settings = await getRecord(db, actor.organizationId, "settings", "settings");
  const timeZone = settings?.currency === "INR" ? "Asia/Kolkata" : "UTC";
  const dayFormatter = new Intl.DateTimeFormat("en-CA", {
    timeZone, year: "numeric", month: "2-digit", day: "2-digit",
  });
  const businessDay = (date: string) => dayFormatter.format(new Date(date));
  const inDate = (date: string) => {
    if (!filters.dateFrom && !filters.dateTo) return true;
    const day = businessDay(date);
    return (!filters.dateFrom || day >= filters.dateFrom) && (!filters.dateTo || day <= filters.dateTo);
  };
  const productFiltered = !!(filters.category || filters.supplierId || filters.sku);
  if (name === "tenders" && productFiltered)
    fail("Tender amounts are recorded per invoice. Remove part filters to reconcile payments.");
  if (filters.paymentType && !["Cash", "Card", "UPI", "Credit"].includes(filters.paymentType))
    fail("Choose a supported payment method.");
  const products = await records(db, actor.organizationId, "product");
  const byProduct = new Map(products.map(p => [p.id, p]));
  const binNames = new Map<string, string>();
  if (name === "stock-movement" || name === "purchase-receipts") {
    for (const bin of await records(db, actor.organizationId, "location", actor.branchId))
      binNames.set(bin.id, [bin.area, bin.rack, bin.shelf, bin.bin].filter(Boolean).join(" / "));
  }
  const productMatch = (product: any) =>
    (!filters.category || product.category === filters.category) &&
    (!filters.supplierId || product.supplierId === filters.supplierId) &&
    (!filters.sku || product.sku === filters.sku);
  const productIds = new Set(
    products.filter(productMatch).map((product) => product.id),
  );
  const lineMatches = (line: any) => !productFiltered || productIds.has(line.productId);
  const needsSales = ["daily-sales", "sales", "returns", "discounts", "margin", "tenders", "tax", "cores", "fitment", "fast-moving", "slow-moving"].includes(name);
  const invoices = needsSales ? await records(db, actor.organizationId, "invoice", actor.branchId) : [];
  const invoicesById = new Map(invoices.map((invoice) => [invoice.id, invoice]));
  const historicalMatch = (line: any) => !productFiltered || productMatch(line);
  const allSales = invoices.filter(
    (sale) =>
      inDate(sale.createdAt) &&
      (!filters.cashier || sale.cashierId === filters.cashier) &&
      (!filters.paymentType ||
        sale.tenders.some(
          (tender: any) => tender.type === filters.paymentType,
        )),
  );
  const sales: any[] = allSales
    .map((sale) => ({
      ...sale,
      lines: sale.lines.filter(historicalMatch),
    }))
    .filter((sale) => sale.lines.length);
  const returns: any[] = (
    needsSales ? await records(db, actor.organizationId, "return", actor.branchId) : []
  )
    .filter(
      (item) =>
        inDate(item.createdAt) &&
        (!filters.cashier || item.userId === filters.cashier) &&
        (!filters.paymentType || refundBy(item, filters.paymentType) > 0),
    )
    .map((item) => ({
      ...item,
      lines: item.lines.filter((line: any) => {
        const original = invoicesById.get(item.invoiceId)?.lines.find((l: any) => l.id === line.lineId);
        return original ? historicalMatch(original) : lineMatches(line);
      }),
    }))
    .filter((item) => item.lines.length);
  const gross = sales.reduce(
    (sum, sale) =>
      sum + sale.lines.reduce((n: number, line: any) => n + line.total, 0),
    0,
  );
  const refundTotal = returns.reduce(
    (sum, item) =>
      sum + item.lines.reduce((n: number, line: any) => n + line.total, 0),
    0,
  );
  const discountTotal = sales.reduce(
    (sum, sale) =>
      sum + sale.lines.reduce((n: number, line: any) => n + line.discount, 0),
    0,
  );
  const tax =
    sales.reduce(
      (sum, sale) =>
        sum + sale.lines.reduce((n: number, line: any) => n + line.tax, 0),
      0,
    ) -
    returns.reduce(
      (sum, item) =>
        sum + item.lines.reduce((n: number, line: any) => n + line.tax, 0),
      0,
    );
  const cost =
    sales.reduce(
      (sum, sale) =>
        sum +
        sale.lines.reduce(
          (n: number, line: any) => n + line.cost * line.qty,
          0,
        ),
      0,
    ) -
    returns.reduce(
      (sum, item) =>
        sum + item.lines.reduce((n: number, line: any) => n + line.cost, 0),
      0,
    );
  const cores = sales.reduce(
    (sum, sale) =>
      sum +
      sale.lines.reduce(
        (n: number, line: any) => n + line.coreCharge * line.qty,
        0,
      ),
    0,
  );
  const coreRefunds = (
    needsSales ? await records(db, actor.organizationId, "coreReturn", actor.branchId) : []
  ).filter(
    (item) =>
      inDate(item.createdAt) &&
      (!productFiltered || invoicesById.get(item.invoiceId)?.lines.some((line: any) =>
        line.productId === item.productId && historicalMatch(line))) &&
      (!filters.cashier || item.userId === filters.cashier) &&
      (!filters.paymentType || refundBy(item, filters.paymentType) > 0),
  );
  const coreRefundTotal = coreRefunds.reduce(
    (sum, item) => sum + item.total,
    0,
  );
  let totals: Record<string, number> = {
    gross,
    returns: refundTotal,
    coreReturns: coreRefundTotal,
    coreDeposits: cores,
    net: gross - refundTotal - coreRefundTotal,
    discount: discountTotal,
    tax,
    cost,
    margin: gross - refundTotal - tax - cost - cores,
    sales: sales.length,
  };
  const flat = sales.flatMap((sale) =>
    sale.lines.map((line: any) => ({
      ...line,
      invoiceId: sale.id,
      number: sale.number,
      createdAt: sale.createdAt,
      cashierId: sale.cashierId,
    })),
  );
  let rows: any[];
  if (name === "daily-sales") {
    // QA #12: before/after discount per day (Billed before discount = Net billed + Discounts).
    const days = new Map<string, { day: string; sales: number; beforeDiscount: number; discount: number; gross: number; returns: number; coreReturns: number; net: number }>();
    const activity = (createdAt: string) => {
      const day = businessDay(createdAt);
      const row = days.get(day) ?? { day, sales: 0, beforeDiscount: 0, discount: 0, gross: 0, returns: 0, coreReturns: 0, net: 0 };
      days.set(day, row);
      return row;
    };
    for (const sale of sales) {
      const row = activity(sale.createdAt);
      row.sales++;
      row.gross += sale.lines.reduce((sum: number, line: any) => sum + line.total, 0);
      row.discount += sale.lines.reduce((sum: number, line: any) => sum + line.discount, 0);
      row.beforeDiscount = row.gross + row.discount;
    }
    for (const item of returns)
      activity(item.createdAt).returns += item.lines.reduce((sum: number, line: any) => sum + line.total, 0);
    for (const item of coreRefunds) activity(item.createdAt).coreReturns += item.total;
    rows = [...days.values()].sort((a, b) => b.day.localeCompare(a.day));
    for (const row of rows) row.net = row.gross - row.returns - row.coreReturns;
  } else if (
    name === "sales" ||
    name === "discounts" ||
    name === "margin"
  ) {
    rows = sales
      .filter((sale) => name !== "discounts" || sale.lines.some((line: any) => line.discount > 0))
      .map((sale) => ({
        id: sale.id,
        invoiceId: sale.id,
        number: sale.number,
        date: sale.createdAt,
        cashierId: sale.cashierId,
        total: sale.lines.reduce(
          (sum: number, line: any) => sum + line.total,
          0,
        ),
        discount: sale.lines.reduce(
          (sum: number, line: any) => sum + line.discount,
          0,
        ),
        tax: sale.lines.reduce((sum: number, line: any) => sum + line.tax, 0),
        cost: sale.lines.reduce(
          (sum: number, line: any) => sum + line.cost * line.qty,
          0,
        ),
        ...(name === "margin" ? { margin: sale.lines.reduce((sum: number, line: any) =>
          sum + line.total - line.tax - (line.cost + line.coreCharge) * line.qty, 0) } : {}),
        tenders: sale.tenders,
      }));
    if (name === "margin") {
      for (const credit of returns) {
        const total = -credit.lines.reduce((n: number, l: any) => n + l.total, 0);
        const tax = -credit.lines.reduce((n: number, l: any) => n + l.tax, 0);
        const cost = -credit.lines.reduce((n: number, l: any) => n + l.cost, 0);
        rows.push({ id: credit.id, invoiceId: credit.invoiceId, number: credit.number,
          date: credit.createdAt, cashierId: credit.userId, total, tax, cost, margin: total - tax - cost });
      }
    }
  } else if (name === "returns") rows = returns.map((item) => ({
    ...item,
    total: item.lines.reduce((sum: number, line: any) => sum + line.total, 0),
    tax: item.lines.reduce((sum: number, line: any) => sum + line.tax, 0),
  }));
  else if (name === "tax")
    rows = flat
      .map((line) => ({
        invoiceId: line.invoiceId,
        document: line.number,
        date: line.createdAt,
        sku: line.sku,
        hsnSac: line.hsnSac || "",
        taxRate: line.taxRate,
        taxable:
          line.subtotal -
          line.discount -
          (line.taxMode === "inclusive" ? line.tax : 0),
        tax: line.tax,
        taxComponents: line.taxComponents || [],
      }))
      .concat(
        returns.flatMap((item) =>
          item.lines.map((line: any) => ({
            invoiceId: item.invoiceId,
            document: item.number,
            date: item.createdAt,
            sku: line.sku,
            hsnSac: line.hsnSac || "",
            taxRate: line.taxRate,
            taxable: -(
              line.subtotal -
              line.discount -
              (line.taxMode === "inclusive" ? line.tax : 0)
            ),
            tax: -line.tax,
            taxComponents: (line.taxComponents || []).map((component: any) => ({
              ...component,
              amount: -component.amount,
            })),
          })),
        ),
      );
  else if (name === "shifts") {
    const shifts = (
      await records(db, actor.organizationId, "shift", actor.branchId)
    ).filter(
      (item) =>
        inDate(item.openedAt) &&
        (!filters.cashier || item.userId === filters.cashier),
    );
    rows = await shiftCashSummaries(db, actor, shifts);
  } else if (name === "cash-movements") {
    rows = (await records(db, actor.organizationId, "cashMovement", actor.branchId))
      .filter(entry => inDate(entry.createdAt) && (!filters.cashier || entry.userId === filters.cashier));
  } else if (name === "tenders")
    // "Credit" = sold on customers' accounts (not money collected).
    // "Online" = paid on the website (collected by the payment gateway).
    rows = ["Cash", "Card", "UPI", "Credit", "Online"]
      .filter((type) => !filters.paymentType || filters.paymentType === type)
      .map((type) => {
        const collected = sales.reduce(
          (sum, sale) =>
            sum +
            sale.tenders
              .filter((tender: any) => tender.type === type)
              .reduce((n: number, tender: any) => n + tender.amount, 0) -
            (type === "Cash" ? sale.change : 0),
          0,
        );
        // Per-tender refund breakdown (returns.ts); an exchange's applied part is not a refund.
        const refunded =
          returns.reduce((sum, item) => sum + refundBy(item, type), 0) +
          coreRefunds.reduce((sum, item) => sum + refundBy(item, type), 0);
        return { type, collected, refunded, net: collected - refunded };
      });
  else if (name === "stock-movement")
    rows = (
      await db.query(
        'SELECT id,product_id AS "productId",bin_id AS "binId",quantity,reason,reference_id AS "referenceId",user_id AS "userId",cost,created_at AS "createdAt" FROM stock_ledger WHERE organization_id=$1 AND branch_id=$2 ORDER BY created_at,id',
        [actor.organizationId, actor.branchId],
      )
    ).rows
      .filter(
        (item) =>
          productIds.has(item.productId) &&
          inDate(new Date(item.createdAt).toISOString()),
      )
      .map((item) => ({
        sku: byProduct.get(item.productId)?.sku ?? item.productId,
        name: byProduct.get(item.productId)?.name,
        location: binNames.get(item.binId) ?? item.binId,
        ...item,
        quantity: Number(item.quantity),
        cost: Number(item.cost),
      }));
  else if (name === "low-stock") {
    const stock = await inventory(db, actor);
    const locations = await records(db, actor.organizationId, "location", actor.branchId);
    const orders = await records(db, actor.organizationId, "purchaseOrder", actor.branchId);
    rows = reorderSuggestions(products.filter(productMatch), stock, locations, orders);
  } else if (["stock-by-bin", "valuation", "aging"].includes(name)) {
    const stock = (await inventory(db, actor)).filter((item) =>
      productIds.has(item.productId),
    );
    const locations = await records(
      db,
      actor.organizationId,
      "location",
      actor.branchId,
    );
    const ledger = (
      await db.query(
        "SELECT product_id,bin_id,quantity,cost,created_at FROM stock_ledger WHERE organization_id=$1 AND branch_id=$2 ORDER BY created_at,id",
        [actor.organizationId, actor.branchId],
      )
    ).rows;
    const lots = remainingLots(ledger);
    rows = stock.map((item) => {
      const product = products.find(
        (product) => product.id === item.productId,
      )!;
      const location = locations.find(
        (location) => location.id === item.binId,
      )!;
      const remaining = lots.get(item.productId + "|" + item.binId) || [];
      const received = remaining[0]?.createdAt;
      return {
        ...item,
        sku: product.sku,
        name: product.name,
        location: [
          location.area,
          location.rack,
          location.shelf,
          location.bin,
        ].join(" / "),
        condition: location.kind,
        cost: product.cost,
        value: item.quantity * product.cost,
        reorderLevel: product.reorderLevel,
        oldestRemainingReceipt: received,
        ageDays: received
          ? Math.floor((Date.now() - new Date(received).getTime()) / 86400000)
          : 0,
        under30: remaining
          .filter((lot) => daysOld(lot.createdAt) < 30)
          .reduce((sum, lot) => sum + lot.quantity, 0),
        days30to90: remaining
          .filter(
            (lot) =>
              daysOld(lot.createdAt) >= 30 && daysOld(lot.createdAt) <= 90,
          )
          .reduce((sum, lot) => sum + lot.quantity, 0),
        over90: remaining
          .filter((lot) => daysOld(lot.createdAt) > 90)
          .reduce((sum, lot) => sum + lot.quantity, 0),
      };
    });
  } else if (name === "fast-moving" || name === "slow-moving") {
    const movement = new Map<string, { productId: string; sku: string; name: string; soldUnits: number; returnedUnits: number; quantity: number; revenue: number }>();
    const bucket = (productId: string, source: any) => {
      let row = movement.get(productId);
      if (!row) {
        row = { productId, sku: source.sku, name: source.name, soldUnits: 0, returnedUnits: 0, quantity: 0, revenue: 0 };
        movement.set(productId, row);
      }
      return row;
    };
    for (const product of products.filter(productMatch)) bucket(product.id, product);
    for (const line of flat) {
      const row = bucket(line.productId, line);
      row.soldUnits += line.qty;
      row.quantity += line.qty;
      row.revenue += line.total;
    }
    for (const credit of returns) {
      for (const line of credit.lines) {
        const row = bucket(line.productId, line);
        row.returnedUnits += line.quantity;
        row.quantity -= line.quantity;
        row.revenue -= line.total;
      }
    }
    rows = [...movement.values()]
      .sort((a, b) =>
        name === "fast-moving"
          ? b.quantity - a.quantity
          : a.quantity - b.quantity,
      );
  } else if (name === "purchase-receipts") {
    const suppliers = await records(db, actor.organizationId, "supplier");
    const supplierNames = new Map(suppliers.map(s => [s.id, s.name]));
    rows = (
      await records(db, actor.organizationId, "purchaseReceipt", actor.branchId)
    )
      .filter(
        (item) =>
          inDate(item.createdAt) &&
          (!filters.supplierId || item.supplierId === filters.supplierId),
      )
      .flatMap((item) =>
        item.lines
          .filter((line: any) => {
            const part = byProduct.get(line.productId);
            return (!filters.category || (line.category ?? part?.category) === filters.category)
              && (!filters.sku || (line.sku ?? part?.sku) === filters.sku);
          })
          .map((line: any) => ({
            id: item.id,
            purchaseOrderId: item.purchaseOrderId,
            date: item.createdAt,
            supplierId: item.supplierId,
            supplier: supplierNames.get(item.supplierId) ?? item.supplierId,
            sku: byProduct.get(line.productId)?.sku ?? line.productId,
            name: byProduct.get(line.productId)?.name,
            location: binNames.get(line.binId) ?? line.binId,
            ...line,
            total: line.cost * line.quantity + line.landedCost,
          })),
      );
  } else if (name === "warranty")
    rows = (
      await records(db, actor.organizationId, "warranty", actor.branchId)
    ).filter((item) => inDate(item.createdAt));
  else if (name === "cores")
    rows = sales
      .flatMap((sale) =>
        sale.lines
          .filter((line: any) => line.coreCharge > 0)
          .map((line: any) => ({
            invoiceId: sale.id,
            number: sale.number,
            productId: line.productId,
            sku: line.sku,
            quantity: line.qty,
            charged: line.coreCharge * line.qty,
          })),
      )
      .concat(
        coreRefunds.map((item) => ({ ...item, refunded: item.total })),
      );
  else if (name === "fitment")
    rows = (
      flat
        .filter((line) =>
          ["incompatible", "unverified"].includes(line.fitment.status),
        )
        .map((line) => ({
          invoiceId: line.invoiceId,
          sku: line.sku,
          status: line.fitment.status,
          reason: line.overrideReason,
          quantity: line.qty,
        })) as any[]
    ).concat(
      returns
        .filter((item) => /fit|wrong part|incompatib/i.test(item.reason))
        .map((item) => ({
          invoiceId: item.invoiceId,
          returnId: item.id,
          reason: item.reason,
          total: item.total,
        })),
    );
  else fail("Unknown report.", 404);
  const sum = (key: string) =>
    rows.reduce((total, row) => total + (Number(row[key]) || 0), 0);
  // QA #12: sales KPIs name their discount basis (labels in report-output.ts).
  if (name === "daily-sales")
    totals = { sales: sales.length, beforeDiscount: gross + discountTotal, discount: discountTotal, gross,
      returns: refundTotal, coreReturns: coreRefundTotal, net: totals.net };
  else if (name === "sales") totals = { sales: totals.sales, beforeDiscount: gross + discountTotal, discount: discountTotal, gross,
      returns: totals.returns, coreReturns: totals.coreReturns, net: totals.net, tax: totals.tax, cost: totals.cost,
      margin: totals.margin, coreDeposits: totals.coreDeposits };
  else if (name === "returns") totals = { creditNotes: rows.length, returns: sum("total"), tax: sum("tax") };
  else if (name === "discounts") totals = { sales: rows.length, discount: sum("discount"), total: sum("total") };
  else if (name === "tax") {
    totals = { taxable: sum("taxable"), tax: sum("tax") };
    const componentKeys: Record<string, string> = { CGST: "cgst", SGST: "sgst", IGST: "igst", UTGST: "utgst" };
    for (const row of rows) {
      for (const component of row.taxComponents) {
        const key = componentKeys[component.name];
        if (!key) continue;
        row[key] = (row[key] ?? 0) + component.amount;
        totals[key] = (totals[key] ?? 0) + component.amount;
      }
    }
  }
  else if (["stock-by-bin", "valuation", "aging"].includes(name))
    totals = {
      quantity: sum("quantity"),
      available: sum("available"),
      reserved: sum("reserved"),
      value: sum("value"),
      under30: sum("under30"),
      days30to90: sum("days30to90"),
      over90: sum("over90"),
    };
  else if (name === "low-stock")
    totals = {
      parts: rows.length,
      suggestedQuantity: sum("suggestedQuantity"),
    };
  else if (name === "stock-movement")
    totals = { movements: rows.length, netQuantity: sum("quantity") };
  else if (name === "purchase-receipts")
    totals = {
      quantity: sum("quantity"),
      landedCost: sum("landedCost"),
      total: sum("total"),
    };
  else if (name === "shifts")
    totals = {
      shifts: rows.length,
      openingCash: sum("openingCash"),
      cashSales: sum("cashSales"),
      cashRefunds: sum("cashRefunds"),
      cashIn: sum("cashIn"),
      cashOut: sum("cashOut"),
      expectedCash: sum("expectedCash"),
      countedCash: sum("countedCash"),
      variance: sum("variance"),
    };
  else if (name === "cash-movements") {
    const cashIn = rows.reduce((sum, entry) => sum + (entry.direction === "in" ? entry.amount : 0), 0);
    const cashOut = rows.reduce((sum, entry) => sum + (entry.direction === "out" ? entry.amount : 0), 0);
    totals = { cashIn, cashOut, netMovement: cashIn - cashOut };
  } else if (name === "tenders")
    totals = {
      collected: sum("collected"),
      refunded: sum("refunded"),
      net: sum("collected") - sum("refunded"),
    };
  else if (name === "warranty")
    totals = {
      claims: rows.length,
      open: rows.filter((row) => !["settled", "rejected"].includes(row.status))
        .length,
    };
  else if (name === "cores")
    totals = {
      charged: sum("charged"),
      refunded: sum("refunded"),
      outstanding: sum("charged") - sum("refunded"),
    };
  else if (["fast-moving", "slow-moving"].includes(name))
    totals = { soldUnits: sum("soldUnits"), returnedUnits: sum("returnedUnits"), quantity: sum("quantity"), revenue: sum("revenue") };
  else if (name === "fitment")
    totals = {
      overrides: rows.filter((row) => row.status).length,
      fitmentReturns: rows.filter((row) => row.returnId).length,
    };
  const conflicts = (
    await records(db, actor.organizationId, "conflict", actor.branchId)
  ).filter((item) => item.status === "pending").length;
  return {
    name,
    rows,
    totals,
    currency: settings?.currency || "INR",
    confirmedOnly: true,
    pendingConflicts: conflicts,
    branchId: actor.branchId,
    timeZone,
    generatedAt: now(),
  };
}

function daysOld(date: string) {
  return Math.floor((Date.now() - new Date(date).getTime()) / 86400000);
}
function remainingLots(ledger: any[]) {
  const result = new Map<string, { quantity: number; createdAt: string }[]>();
  const deficits = new Map<string, number>();
  for (const movement of ledger) {
    const key = movement.product_id + "|" + movement.bin_id;
    const lots = result.get(key) || [];
    let quantity = Number(movement.quantity);
    if (quantity > 0) {
      const covered = Math.min(quantity, deficits.get(key) || 0);
      quantity -= covered;
      deficits.set(key, (deficits.get(key) || 0) - covered);
      if (quantity)
        lots.push({
          quantity,
          createdAt: new Date(movement.created_at).toISOString(),
        });
    } else {
      let remove = -quantity;
      while (remove > 0 && lots.length) {
        const taken = Math.min(remove, lots[0].quantity);
        remove -= taken;
        lots[0].quantity -= taken;
        if (!lots[0].quantity) lots.shift();
      }
      if (remove) deficits.set(key, (deficits.get(key) || 0) + remove);
    }
    result.set(key, lots);
  }
  return result;
}
