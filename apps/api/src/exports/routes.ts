// WS-F: accounting exports from the Reports workspace.
//   GET /api/v1/exports/gstr1?dateFrom&dateTo[&branches=all]
//       format: (none) summary + portal JSON + CSV sections preview
//               portal | csv&section=b2b|b2cl|b2cs|cdnr|cdnur|hsn-b2b|hsn-b2c | xlsx
//   GET /api/v1/exports/tally?dateFrom&dateTo&vouchers=sales|purchases|all|ledgers
// Add delivery=json to get {fileName, content|base64} (what the app downloads with).
import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import { gstr1, gstr1Csv, gstr1Sheets } from "./gstr1.js";
import { tallyVouchers, tallyXml } from "./tally.js";
import { XLSX_TYPE, xlsx } from "./xlsx.js";

function send(reply: any, query: any, fileName: string, type: string, body: string | Buffer) {
  if (query.delivery === "json")
    return typeof body === "string" ? { fileName, content: body } : { fileName, base64: body.toString("base64") };
  return reply.type(type).header("Content-Disposition", `attachment; filename="${fileName}"`).send(body);
}

export function exportRoutes(app: FastifyInstance, db: Database) {
  app.get("/api/v1/exports/gstr1", async (request: any, reply) => {
    const query = request.query ?? {};
    const result = await db.readSnapshot((snapshot) => gstr1(snapshot, request.actor, query));
    const base = `GSTR1-${result.summary.gstin}-${result.summary.period}`;
    if (query.format === "portal")
      return send(reply, query, base + ".json", "application/json; charset=utf-8", JSON.stringify(result.portal, null, 1));
    if (query.format === "csv")
      return send(reply, query, `${base}-${query.section}.csv`, "text/csv; charset=utf-8", "﻿" + gstr1Csv(result, String(query.section)));
    if (query.format === "xlsx") return send(reply, query, base + ".xlsx", XLSX_TYPE, xlsx(gstr1Sheets(result)));
    return result;
  });
  app.get("/api/v1/exports/tally", async (request: any, reply) => {
    const query = request.query ?? {};
    const result = await db.readSnapshot((snapshot) => tallyVouchers(snapshot, request.actor, query));
    if (query.format === "json") return result;
    const name = result.kind === "ledgers" ? "tally-ledgers" : `tally-${result.kind}-${query.dateFrom}-to-${query.dateTo}`;
    return send(reply, query, name + ".xml", "application/xml; charset=utf-8", tallyXml(result));
  });
}
