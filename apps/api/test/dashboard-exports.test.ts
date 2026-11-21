// WS-F: owner command center aggregates, GSTR-1 (vs the tax report), Tally XML and Excel exports.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { inflateRawSync } from "node:zlib";
import { connectDatabase, migrate } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed } from "../src/seed.js";
import { crc32, xlsx, zip } from "../src/exports/xlsx.js";

/** Reads the files back out of a zip produced by our writer. */
function unzip(data: Buffer) {
  const files = new Map<string, string>();
  let at = 0;
  while (data.readUInt32LE(at) === 0x04034b50) {
    const size = data.readUInt32LE(at + 18), nameLength = data.readUInt16LE(at + 26), extra = data.readUInt16LE(at + 28);
    const name = data.subarray(at + 30, at + 30 + nameLength).toString("utf8");
    const body = data.subarray(at + 30 + nameLength + extra, at + 30 + nameLength + extra + size);
    const content = inflateRawSync(body);
    assert.equal(crc32(content), data.readUInt32LE(at + 14), name + " checksum");
    files.set(name, content.toString("utf8"));
    at += 30 + nameLength + extra + size;
  }
  return files;
}

test("xlsx writer produces a valid workbook with escaped text and money numbers", () => {
  const book = unzip(xlsx([{ name: "Sales/Nov", header: ["Item", "Total (INR)"], rows: [["Oil <5W-30> & filter", 1234.5], [null, -2]],
    formats: ["text", "money"] }]));
  assert.ok(book.has("[Content_Types].xml") && book.has("xl/workbook.xml") && book.has("xl/styles.xml"));
  assert.match(book.get("xl/workbook.xml")!, /name="Sales Nov"/);
  const sheet = book.get("xl/worksheets/sheet1.xml")!;
  assert.match(sheet, /Oil &lt;5W-30&gt; &amp; filter/);
  assert.match(sheet, /<c r="B2" s="1"><v>1234.5<\/v><\/c>/);
  assert.match(sheet, /<c r="B3" s="1"><v>-2<\/v><\/c>/);
  assert.match(sheet, /state="frozen"/);
  assert.equal(zip([{ name: "a.txt", data: Buffer.from("x") }]).readUInt32LE(0), 0x04034b50);
});

test("command center, GSTR-1, Tally and Excel exports agree with the sales and tax reports", async () => {
  const db = await connectDatabase({ memory: true });
  await migrate(db);
  await seed(db);
  const app = await createApp(db);
  try {
    async function raw(path: string, token: string, body?: any) {
      return app.inject({ method: body === undefined ? "GET" : "POST", url: "/api/v1/" + path, payload: body,
        headers: { authorization: "Bearer " + token } });
    }
    async function call(path: string, token: string, body?: any, status = 200) {
      const response = await raw(path, token, body);
      assert.equal(response.statusCode, status, path + ": " + response.body);
      return response.headers["content-type"]?.toString().includes("json") ? response.json() : response.body;
    }
    const login = async (role: string) => (await app.inject({ method: "POST", url: "/api/v1/auth/login",
      payload: { email: role + "@motorline.local", password: "MotorlineDemo123!", branchId: "pune" } })).json().token;
    const owner = await login("owner");
    const manager = await login("manager");
    const cashier = await login("cashier");

    await call("dashboard", cashier, undefined, 403);
    await call("exports/gstr1?dateFrom=2026-01-01&dateTo=2026-01-31", cashier, undefined, 403);
    // GSTR-1 needs GST turned on.
    await call("exports/gstr1?dateFrom=2026-01-01&dateTo=2026-01-31", owner, undefined, 409);
    await call("settings", owner, {
      taxScheme: "india-gst", taxMode: "exclusive", invoicePrefix: "INV", creditNotePrefix: "CR",
      business: { legalName: "Cartunez Test", address: "MG Road\nPune", stateCode: "27", taxRegistrationId: "27ABCDE1234F1Z5" },
      branchStateCode: "27",
    });
    const part = await call("products", owner, { name: "Cabin Filter", sku: "CAB-01", brand: "Test", category: "Filters", unit: "Each",
      cost: 50000, retailPrice: 100000, taxRate: 1800, hsnSac: "84213100", universal: true, reorderLevel: 0, barcodes: ["CTZ-CAB-01"] });
    const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata" }).format(new Date());
    await call("purchase-bills", owner, { transactionId: randomUUID(), supplierId: "supplier-1", billNumber: "SB-1", billDate: today,
      lines: [{ productId: part.id, quantity: 10, cost: 50000, binId: "bin-a1" }], otherCharges: 1000, discount: 0 });
    const gstCustomer = await call("customers", owner, { name: "Fleet Motors Pvt Ltd", phone: "9000000200",
      address: "Whitefield\nBengaluru", taxRegistrationId: "29ABCDE1234F1Z5", stateCode: "29" });

    const shift = await call("shifts/open", owner, { openingCash: 10000 });
    const sell = (body: any) => call("invoices", owner, { transactionId: randomUUID(), shiftId: shift.id, ...body });
    const walkIn = await sell({ placeOfSupply: "27", lines: [{ productId: part.id, qty: 1, binId: "bin-a1" }], tenders: [{ type: "Cash", amount: 120000, confirmed: true }] });
    assert.equal(walkIn.total, 118000);
    const b2b = await sell({ customerId: gstCustomer.id, lines: [{ productId: part.id, qty: 2, binId: "bin-a1" }],
      tenders: [{ type: "Card", amount: 236000, confirmed: true, reference: "4421" }] });
    assert.equal(b2b.taxComponents[0].name, "IGST");
    const credit = await sell({ customerId: "customer-1", placeOfSupply: "27", lines: [{ productId: part.id, qty: 1, binId: "bin-a1" }],
      tenders: [{ type: "Credit", amount: 118000 }] });
    await call(`invoices/${b2b.id}/returns`, owner, { transactionId: randomUUID(), condition: "sellable", reason: "Wrong size",
      refundType: "Card", lines: [{ lineId: b2b.lines[0].id, quantity: 1, binId: "bin-a1" }] });
    await call(`invoices/${walkIn.id}/returns`, owner, { transactionId: randomUUID(), condition: "sellable", reason: "Not needed",
      refundType: "Cash", lines: [{ lineId: walkIn.lines[0].id, quantity: 1, binId: "bin-a1" }] });
    // A manager's shift closed 5 rupees over.
    const other = await call("shifts/open", manager, { openingCash: 0 });
    await call(`shifts/${other.id}/close`, manager, { countedCash: 500 });

    // ---------- Command center ----------
    const board = await call("dashboard", owner);
    assert.equal(board.tills.length, 1);
    const till = board.tills[0];
    const shiftRow = (await call("reports/shifts", owner)).rows.find((s: any) => s.id === shift.id);
    assert.equal(till.cashOnHand, shiftRow.expectedCash);
    assert.equal(till.cashOnHand, 10000 + 118000 - 118000);
    assert.equal(till.sales, 3);
    assert.equal(till.lastSaleAt, credit.createdAt);
    const range = `dateFrom=${today}&dateTo=${today}`;
    const daily = await call(`reports/daily-sales?${range}`, owner);
    assert.equal(board.today.sales, 3);
    assert.equal(board.today.net, daily.totals.net);
    const margin = await call(`reports/margin?${range}`, owner);
    assert.equal(board.today.margin, margin.rows.reduce((n: number, r: any) => n + r.margin, 0));
    assert.equal(board.hourly.length, 24);
    assert.equal(board.hourly.reduce((n: number, h: any) => n + h.net, 0), board.today.net);
    assert.equal(board.hourly.reduce((n: number, h: any) => n + h.margin, 0), board.today.margin);
    assert.equal(board.customerDues.total, 118000);
    assert.equal(board.customerDues.rows[0].customerId, "customer-1");
    assert.deepEqual(board.varianceShifts.map((s: any) => [s.shiftId, s.variance]), [[other.id, 500]]);
    assert.equal(board.topItems[0].productId, part.id);
    assert.equal(board.topItems[0].quantity, 2);
    assert.equal(board.lowStock.count, (await call("reports/low-stock", owner)).rows.length);
    // Everything was received today, so nothing is dead yet...
    assert.equal(board.deadStock.count, 0);
    // ...but half a year from now, the unsold stock is.
    const later = new Date(Date.now() + 200 * 86400000).toISOString();
    const future = await call(`dashboard?deadDays=90&at=${later}`, owner);
    const cabin = future.deadStock.rows.find((r: any) => r.productId === part.id) ??
      (future.deadStock.count > 8 ? null : assert.fail("cabin filter missing from dead stock"));
    if (cabin) assert.equal(cabin.value, cabin.quantity * 50000 + cabin.quantity * Math.round(1000 / 10));
    assert.ok(future.deadStock.value > 0);
    await call("dashboard?deadDays=3", owner, undefined, 400);

    // ---------- GSTR-1 against the tax report ----------
    const tax = await call(`reports/tax?${range}`, owner);
    const g = await call(`exports/gstr1?${range}`, owner);
    assert.equal(g.summary.taxable, tax.totals.taxable);
    assert.equal(g.summary.tax, tax.totals.tax);
    assert.equal(g.summary.igst, tax.totals.igst ?? 0);
    assert.equal(g.summary.cgst, tax.totals.cgst ?? 0);
    assert.equal(g.summary.sgst, tax.totals.sgst ?? 0);
    assert.equal(g.summary.taxable, 200000);
    const portal = g.portal;
    assert.equal(portal.gstin, "27ABCDE1234F1Z5");
    assert.equal(portal.fp, today.slice(5, 7) + today.slice(0, 4));
    assert.equal(portal.b2b[0].ctin, "29ABCDE1234F1Z5");
    assert.deepEqual(portal.b2b[0].inv[0].itms[0].itm_det, { rt: 18, txval: 2000, iamt: 360, camt: 0, samt: 0, csamt: 0 });
    assert.equal(portal.b2b[0].inv[0].pos, "29");
    assert.equal(portal.cdnr[0].nt[0].ntty, "C");
    assert.deepEqual(portal.cdnr[0].nt[0].itms[0].itm_det, { rt: 18, txval: 1000, iamt: 180, camt: 0, samt: 0, csamt: 0 });
    // B2CS nets the walk-in sale, its return and the credit sale: one Rs 1,000 sale left.
    assert.deepEqual(portal.b2cs, [{ sply_ty: "INTRA", pos: "27", typ: "OE", rt: 18, txval: 1000, iamt: 0, camt: 90, samt: 90, csamt: 0 }]);
    // Every section adds up to the summary.
    const sum = (list: any[], key: string) => list.reduce((n, x) => n + x[key], 0);
    const b2bTx = portal.b2b.flatMap((c: any) => c.inv.flatMap((i: any) => i.itms.map((t: any) => t.itm_det)));
    const cdnTx = portal.cdnr.flatMap((c: any) => c.nt.flatMap((i: any) => i.itms.map((t: any) => t.itm_det)));
    assert.equal(Math.round((sum(b2bTx, "txval") + sum(portal.b2cs, "txval") - sum(cdnTx, "txval")) * 100), tax.totals.taxable);
    const hsn = [...portal.hsn.hsn_b2b, ...portal.hsn.hsn_b2c];
    assert.equal(Math.round(sum(hsn, "txval") * 100), tax.totals.taxable);
    assert.deepEqual(portal.hsn.hsn_b2b.map((r: any) => [r.hsn_sc, r.uqc, r.qty, r.rt]), [["84213100", "NOS", 1, 18]]);
    assert.deepEqual(portal.hsn.hsn_b2c.map((r: any) => [r.hsn_sc, r.qty]), [["84213100", 1]]);
    const b2bCsv = await call(`exports/gstr1?${range}&format=csv&section=b2b`, owner) as string;
    const csvLines = b2bCsv.replace(/^﻿/, "").split("\r\n");
    assert.equal(csvLines[0].split(",")[0], '"GSTIN/UIN of Recipient"');
    assert.match(csvLines[1], /"29ABCDE1234F1Z5","Fleet Motors Pvt Ltd","INV-PUNE-\d+","\d\d-[A-Z][a-z]{2}-\d{4}","2360","29-Karnataka","N","","Regular B2B","","18","2000","0"/);
    const hsnCsv = (await call(`exports/gstr1?${range}&format=csv&section=hsn-b2c`, owner) as string).split("\r\n");
    assert.match(hsnCsv[1], /"84213100","Cabin Filter","NOS-NUMBERS","1","1180","18","1000","0","90","90","0"/);
    await call(`exports/gstr1?${range}&format=csv&section=nope`, owner, undefined, 400);
    const download = await raw(`exports/gstr1?${range}&format=portal`, owner);
    assert.match(String(download.headers["content-disposition"]), /GSTR1-27ABCDE1234F1Z5-\d{6}\.json/);
    assert.deepEqual(JSON.parse(download.body), portal);
    const book = await call(`exports/gstr1?${range}&format=xlsx&delivery=json`, owner);
    const sheets = unzip(Buffer.from(book.base64, "base64"));
    assert.match(sheets.get("xl/workbook.xml")!, /name="b2b".*name="b2cs".*name="hsn-b2c"/);
    await call(`exports/gstr1?dateFrom=${today}&dateTo=2020-01-01`, owner, undefined, 400);
    await call(`exports/gstr1?${range}&branches=all`, manager, undefined, 403);
    assert.equal((await call(`exports/gstr1?${range}&branches=all`, owner)).summary.taxable, 200000);

    // ---------- Tally ----------
    const xml = await call(`exports/tally?${range}&vouchers=all`, owner) as string;
    const vouchers = [...xml.matchAll(/<VOUCHER VCHTYPE="([^"]+)"[\s\S]*?<\/VOUCHER>/g)];
    assert.deepEqual(vouchers.map((v) => v[1]).sort(), ["Credit Note", "Credit Note", "Purchase", "Sales", "Sales", "Sales"]);
    for (const [voucher] of vouchers) {
      const amounts = [...voucher.matchAll(/<AMOUNT>(-?\d+\.\d\d)<\/AMOUNT>/g)].map((m) => Math.round(Number(m[1]) * 100));
      assert.equal(amounts.reduce((n, a) => n + a, 0), 0, "voucher balances: " + voucher);
      for (const entry of voucher.matchAll(/<ISDEEMEDPOSITIVE>(Yes|No)<\/ISDEEMEDPOSITIVE><AMOUNT>(-?[\d.]+)<\/AMOUNT>/g))
        assert.equal(entry[1] === "Yes", Number(entry[2]) < 0);
    }
    const sale = vouchers.find((v) => v[0].includes(b2b.number))![0];
    assert.match(sale, /<LEDGERNAME>Card Receipts<\/LEDGERNAME><ISDEEMEDPOSITIVE>Yes<\/ISDEEMEDPOSITIVE><AMOUNT>-2360.00<\/AMOUNT>/);
    assert.match(sale, /<LEDGERNAME>Sales @ 18%<\/LEDGERNAME><ISDEEMEDPOSITIVE>No<\/ISDEEMEDPOSITIVE><AMOUNT>2000.00<\/AMOUNT>/);
    assert.match(sale, /<LEDGERNAME>Output IGST<\/LEDGERNAME><ISDEEMEDPOSITIVE>No<\/ISDEEMEDPOSITIVE><AMOUNT>360.00<\/AMOUNT>/);
    const cashSale = vouchers.find((v) => v[0].includes(walkIn.number) && v[1] === "Sales")![0];
    assert.match(cashSale, /<DATE>\d{8}<\/DATE>/);
    assert.match(cashSale, /<LEDGERNAME>Cash<\/LEDGERNAME><ISDEEMEDPOSITIVE>Yes<\/ISDEEMEDPOSITIVE><AMOUNT>-1180.00<\/AMOUNT>/);
    const creditSale = vouchers.find((v) => v[0].includes(credit.number))![0];
    assert.match(creditSale, /<PARTYLEDGERNAME>Arjun Demo<\/PARTYLEDGERNAME>/);
    const purchase = vouchers.find((v) => v[1] === "Purchase")![0];
    assert.match(purchase, /<LEDGERNAME>Fictional Auto Supply<\/LEDGERNAME><ISDEEMEDPOSITIVE>No<\/ISDEEMEDPOSITIVE><AMOUNT>5010.00<\/AMOUNT>/);
    assert.match(purchase, /<LEDGERNAME>Freight and Other Charges<\/LEDGERNAME>/);
    const salesOnly = await call(`exports/tally?${range}&vouchers=sales&delivery=json`, owner);
    assert.match(salesOnly.fileName, /^tally-sales-/);
    assert.ok(!salesOnly.content.includes('VCHTYPE="Purchase"'));
    const masters = await call(`exports/tally?${range}&vouchers=ledgers`, owner) as string;
    assert.match(masters, /<LEDGER NAME="Fleet Motors Pvt Ltd" ACTION="Create"><NAME>Fleet Motors Pvt Ltd<\/NAME><PARENT>Sundry Debtors<\/PARENT>/);
    assert.match(masters, /<LEDGER NAME="Fictional Auto Supply"[^>]*><NAME>[^<]+<\/NAME><PARENT>Sundry Creditors<\/PARENT>/);
    assert.match(masters, /<NAME>Output IGST<\/NAME><PARENT>Duties &amp; Taxes<\/PARENT>/);
    assert.match(masters, /<NAME>Cash<\/NAME><PARENT>Cash-in-Hand<\/PARENT>/);
    await call(`exports/tally?${range}&vouchers=stock`, owner, undefined, 400);

    // ---------- Reports as CSV and Excel ----------
    const csv = await call(`reports/sales?${range}&format=csv`, owner) as string;
    assert.equal(csv.split("\r\n").length, 4);
    const excel = await raw(`reports/sales?${range}&format=xlsx`, owner);
    assert.equal(excel.headers["content-type"], "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    const workbook = unzip(excel.rawPayload);
    const sheet = workbook.get("xl/worksheets/sheet1.xml")!;
    assert.match(sheet, /total \(INR\)/);
    assert.match(sheet, /<v>2360<\/v>/);
    const wrapped = await call(`reports/tax?${range}&format=xlsx-json`, owner);
    assert.equal(wrapped.fileName, "tax.xlsx");
    assert.match(unzip(Buffer.from(wrapped.base64, "base64")).get("xl/workbook.xml")!, /name="tax".*name="Totals"/);
  } finally {
    await app.close();
    await db.close();
  }
});
