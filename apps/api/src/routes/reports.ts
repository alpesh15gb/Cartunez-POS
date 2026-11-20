import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import { reportOutput } from "../report-output.js";
import { compareTenderStatement } from "../tender-comparison.js";
import { report } from "../reports.js";

export function reportRoutes(app: FastifyInstance, db: Database) {
  app.post("/api/v1/reports/tenders/compare", async (request: any) =>
    db.readSnapshot(snapshot => compareTenderStatement(snapshot, request.actor, request.body ?? {})));
  app.get("/api/v1/reports/:name", async (request: any, reply) => {
    const result = await db.readSnapshot((snapshot) => report(
      snapshot,
      request.actor,
      request.params.name,
      request.query,
    ));
    const output = reportOutput(result, request.query);
    if (typeof output === "string")
      return reply.type("text/csv; charset=utf-8")
        .header("Content-Disposition", `attachment; filename="${result.name}.csv"`).send(output);
    return output;
  });
}
