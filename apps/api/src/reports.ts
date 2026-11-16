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
  const inDate = (date: string) =>
    (!filters.dateFrom || date.slice(0, 10) >= filters.dateFrom) &&
    (!filters.dateTo || date.slice(0, 10) <= filters.dateTo);
  const products = await records(db, actor.organizationId, "product");
  const productMatch = (product: any) =>
    (!filters.category || product.category === filters.category) &&
    (!filters.supplierId || product.supplierId === filters.supplierId) &&
    (!filters.sku || product.sku === filters.sku);
  const productIds = new Set(
    products.filter(productMatch).map((product) => product.id),
  );
  const allSales = (
    await records(db, actor.organizationId, "invoice", actor.branchId)
  ).filter(
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
      lines: sale.lines.filter((line: any) => productIds.has(line.productId)),
    }))
    .filter((sale) => sale.lines.length);
  const returns: any[] = (
    await records(db, actor.organizationId, "return", actor.branchId)
  )
    .filter(
      (item) =>
        inDate(item.createdAt) &&
        (!filters.cashier || item.userId === filters.cashier) &&
        (!filters.paymentType || item.refundType === filters.paymentType),
    )
    .map((item) => ({
      ...item,
      lines: item.lines.filter((line: any) => productIds.has(line.productId)),
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
    await records(db, actor.organizationId, "coreReturn", actor.branchId)
  ).filter(
    (item) =>
      inDate(item.createdAt) &&
      productIds.has(item.productId) &&
      (!filters.paymentType || item.refundType === filters.paymentType),
  );
  const coreRefundTotal = coreRefunds.reduce(
    (sum, item) => sum + item.total,
    0,
  );
  let totals: Record<string, number> = {
    gross,
    returns: refundTotal,
    coreReturns: coreRefundTotal,
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
  if (
    name === "sales" ||
    name === "discounts" ||
    name === "margin" ||
    name === "daily-sales"
  )
    rows = sales
      .filter((sale) => name !== "discounts" || sale.discount > 0)
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
        tenders: sale.tenders,
      }));
  else if (name === "returns") rows = returns;
  else if (name === "tax")
    rows = flat
      .map((line) => ({
        invoiceId: line.invoiceId,
        sku: line.sku,
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
            sku: line.sku,
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
  else if (name === "shifts")
    rows = (
      await records(db, actor.organizationId, "shift", actor.branchId)
    ).filter(
      (item) =>
        inDate(item.openedAt) &&
        (!filters.cashier || item.userId === filters.cashier),
    );
  else if (name === "tenders")
    rows = ["Cash", "Card", "UPI"]
      .filter((type) => !filters.paymentType || filters.paymentType === type)
      .map((type) => ({
        type,
        collected: sales.reduce(
          (sum, sale) =>
            sum +
            sale.tenders
              .filter((tender: any) => tender.type === type)
              .reduce((n: number, tender: any) => n + tender.amount, 0) -
            (type === "Cash" ? sale.change : 0),
          0,
        ),
        refunded:
          returns
            .filter((item) => item.refundType === type)
            .reduce((sum, item) => sum + item.total, 0) +
          coreRefunds
            .filter((item) => item.refundType === type)
            .reduce((sum, item) => sum + item.total, 0),
      }));
  else if (name === "stock-movement")
    rows = (
      await db.query(
        'SELECT id,product_id AS "productId",bin_id AS "binId",quantity,reason,reference_id AS "referenceId",user_id AS "userId",cost,created_at AS "createdAt" FROM stock_ledger WHERE organization_id=$1 AND branch_id=$2 ORDER BY created_at',
        [actor.organizationId, actor.branchId],
      )
    ).rows
      .filter(
        (item) =>
          productIds.has(item.productId) &&
          inDate(new Date(item.createdAt).toISOString()),
      )
      .map((item) => ({
        ...item,
        quantity: Number(item.quantity),
        cost: Number(item.cost),
      }));
  else if (["stock-by-bin", "valuation", "low-stock", "aging"].includes(name)) {
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
    if (name === "low-stock")
      rows = products
        .filter(productMatch)
        .filter((product) => product.type !== "service")
        .map((product) => {
          const available = stock
            .filter(
              (item) =>
                item.productId === product.id &&
                locations.find((location) => location.id === item.binId)
                  ?.kind === "sellable",
            )
            .reduce((sum, item) => sum + item.available, 0);
          return {
            productId: product.id,
            sku: product.sku,
            name: product.name,
            available,
            reorderLevel: product.reorderLevel,
            suggestedQuantity: Math.max(
              0,
              product.reorderLevel * 2 - available,
            ),
            supplierId: product.supplierId,
          };
        })
        .filter((item) => item.available <= item.reorderLevel);
  } else if (name === "fast-moving" || name === "slow-moving") {
    rows = products
      .filter(productMatch)
      .map((product) => ({
        productId: product.id,
        sku: product.sku,
        name: product.name,
        quantity: flat
          .filter((line) => line.productId === product.id)
          .reduce((sum, line) => sum + line.qty, 0),
        revenue: flat
          .filter((line) => line.productId === product.id)
          .reduce((sum, line) => sum + line.total, 0),
      }))
      .sort((a, b) =>
        name === "fast-moving"
          ? b.quantity - a.quantity
          : a.quantity - b.quantity,
      );
  } else if (name === "purchase-receipts")
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
          .filter((line: any) => productIds.has(line.productId))
          .map((line: any) => ({
            id: item.id,
            purchaseOrderId: item.purchaseOrderId,
            date: item.createdAt,
            supplierId: item.supplierId,
            ...line,
            total: line.cost * line.quantity + line.landedCost,
          })),
      );
  else if (name === "warranty")
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
        (await records(db, actor.organizationId, "coreReturn", actor.branchId))
          .filter((item) => inDate(item.createdAt))
          .map((item) => ({ ...item, refunded: item.total })),
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
  if (["stock-by-bin", "valuation", "aging"].includes(name))
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
      expectedCash: sum("expectedCash"),
      countedCash: sum("countedCash"),
      variance: sum("variance"),
    };
  else if (name === "tenders")
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
    totals = { quantity: sum("quantity"), revenue: sum("revenue") };
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
    confirmedOnly: true,
    pendingConflicts: conflicts,
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
