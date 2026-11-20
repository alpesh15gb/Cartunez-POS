import { parse } from "csv-parse/sync";
import type { Database } from "./db.js";
import { getRecord } from "./db.js";
import { allow, fail, type Actor } from "./domain.js";

type Entry = { date: string; amount: number; document: string };
type Group = { type: string; reference: string; pos: Entry[]; statement: Entry[] };
const columns = ["date", "type", "reference", "gross_inr"];
const datePattern = /^\d{4}-\d{2}-\d{2}$/;
function validDay(value: unknown): value is string {
  if (typeof value !== "string" || !datePattern.test(value) || value.startsWith("0000-")) return false;
  const time = Date.parse(value + "T00:00:00Z");
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value;
}

export async function compareTenderStatement(db: Database, actor: Actor, body: any) {
  allow(actor, ["owner", "manager"]);
  if (body.branchId && body.branchId !== actor.branchId) fail("Switch to the branch for this statement.", 403);
  const { from, to, csv } = body;
  if (!validDay(from) || !validDay(to) || from > to) fail("Choose a valid statement date range.");
  const method = body.type ?? "Both";
  if (!["Both", "Card", "UPI"].includes(method)) fail("Choose Card, UPI, or both.");
  if (typeof csv !== "string" || !csv.trim() || Buffer.byteLength(csv, "utf8") > 512 * 1024)
    fail("Provide a UTF-8 CSV up to 512 KiB.");
  if ((await getRecord(db, actor.organizationId, "settings", "settings"))?.currency !== "INR")
    fail("This comparison uses INR statements.");
  let table: string[][];
  try {
    table = parse(csv, { bom: true, trim: true, skip_empty_lines: true, max_record_size: 4096 });
  } catch {
    fail("Invalid CSV. Check the quoting and the number of columns in each row.");
  }
  const header = table.shift() ?? [];
  if (header.length !== columns.length || !columns.every(name => header.includes(name)))
    fail("Use exactly these headers: date,type,reference,gross_inr.");
  if (table.length > 5000) fail("Use a smaller date range and up to 5,000 statement lines.");
  const groups = new Map<string, Group>();
  const group = (type: string, reference: string) => {
    const key = JSON.stringify([type, reference]);
    let item = groups.get(key);
    if (!item) {
      item = { type, reference, statement: [], pos: [] };
      groups.set(key, item);
    }
    return item;
  };
  let excluded = 0, statementGross = 0, statementCount = 0;
  const indexes = columns.map(c => header.indexOf(c));
  for (const [index, values] of table.entries()) {
    const [date, rawType, reference, gross] = indexes.map(i => values[i]);
    const type = rawType.toLowerCase() === "card" ? "Card" : rawType.toUpperCase();
    const sourceRow = index + 2;
    if (!validDay(date) || !["Card", "UPI"].includes(type) || !reference || reference.length > 200 || /[\x00-\x1f]/.test(reference))
      fail(`Check the date, payment type and provider reference in CSV row ${sourceRow}.`);
    const match = /^(\d{1,10})(?:\.(\d{1,2}))?$/.exec(gross);
    const amount = match && Number(match[1]) * 100 + Number((match[2] ?? "").padEnd(2, "0"));
    if (!amount || amount > 100000000000) fail(`Enter a positive gross INR amount with up to two decimals in CSV row ${sourceRow}.`);
    if (date < from || date > to || method !== "Both" && method !== type) { excluded++; continue; }
    group(type, reference).statement.push({ date, amount, document: `CSV row ${sourceRow}` });
    statementGross += amount;
    statementCount++;
  }
  // Match the POS business day, including midnight boundaries, to the provider capture day.
  const { rows } = await db.query(
    `SELECT data->>'number' AS number, data->>'currency' AS currency,
            to_char((data->>'createdAt')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD') AS day,
            tender->>'reference' AS reference, tender->>'type' AS type, tender->>'amount' AS amount
       FROM records CROSS JOIN LATERAL jsonb_array_elements(data->'tenders') tender
      WHERE organization_id=$1 AND branch_id=$2 AND kind='invoice'
        AND (data->>'createdAt')::timestamptz >= ($3::date::timestamp AT TIME ZONE 'Asia/Kolkata')
        AND (data->>'createdAt')::timestamptz < (($4::date + 1)::timestamp AT TIME ZONE 'Asia/Kolkata')
        AND tender->>'type' IN ('Card','UPI') AND ($5='Both' OR tender->>'type'=$5)
        AND (tender->>'amount')::bigint > 0
      ORDER BY data->>'createdAt', id LIMIT 5001`,
    [actor.organizationId, actor.branchId, from, to, method],
  );
  if (rows.length > 5000) fail("Choose a shorter date range with up to 5,000 POS card or UPI entries.");
  let posGross = 0;
  for (const row of rows) {
    if (row.currency !== "INR") fail("The selected period contains receipts outside INR. Select an INR-only period.");
    const amount = Number(row.amount);
    group(row.type, (row.reference ?? "").trim()).pos.push({ amount, date: row.day, document: row.number });
    posGross += amount;
  }
  const compared = [...groups.values()].map(item => {
    const { pos, statement } = item;
    let status: string;
    if (!item.reference) status = "POS reference missing";
    else if (pos.length > 1 || statement.length > 1) status = "Ambiguous reference";
    else if (!pos.length) status = "Missing in POS";
    else if (!statement.length) status = "Missing on statement";
    else {
      const amountDiffers = pos[0].amount !== statement[0].amount;
      const dateDiffers = pos[0].date !== statement[0].date;
      status = amountDiffers && dateDiffers ? "Amount and date differ"
        : amountDiffers ? "Amount differs" : dateDiffers ? "Date differs" : "Matched";
    }
    return { ...item, status };
  });
  const matched = compared.filter(row => row.status === "Matched").length;
  compared.sort((a, b) => Number(a.status === "Matched") - Number(b.status === "Matched") ||
    a.type.localeCompare(b.type) || a.reference.localeCompare(b.reference));
  return { from, to, branchId: actor.branchId, type: method, rows: compared,
    posCount: rows.length, posGross, statementCount, statementGross, excluded,
    matched, exceptions: compared.length - matched, difference: statementGross - posGross };
}
