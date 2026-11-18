import { Pool } from "pg";
import { PGlite } from "@electric-sql/pglite";
import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";

export interface QueryResult {
  rows: any[];
  rowCount?: number | null;
}
export interface Database {
  query(sql: string, values?: unknown[]): Promise<QueryResult>;
  transaction<T>(fn: (db: Database) => Promise<T>): Promise<T>;
  readSnapshot<T>(fn: (db: Database) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
export async function connectDatabase(
  options: { memory?: boolean; dataDir?: string } = {},
): Promise<Database> {
  if (process.env.DATABASE_URL) {
    const pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 10,
    });
    return {
      query: (sql, values) => pool.query(sql, values),
      async transaction(fn) {
        const client = await pool.connect();
        try {
          await client.query("BEGIN");
          await client.query(
            "SELECT revision FROM installation_lock WHERE id=1 FOR UPDATE",
          );
          const tx: Database = {
            query: (sql, values) => client.query(sql, values),
            transaction: async (callback) => callback(tx),
            readSnapshot: async (callback) => callback(tx),
            close: async () => {},
          };
          const result = await fn(tx);
          await client.query("COMMIT");
          return result;
        } catch (error) {
          await client.query("ROLLBACK");
          throw error;
        } finally {
          client.release();
        }
      },
      async readSnapshot(fn) {
        const client = await pool.connect();
        try {
          await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
          const snapshot: Database = {
            query: (sql, values) => client.query(sql, values),
            transaction: async (callback) => callback(snapshot),
            readSnapshot: async (callback) => callback(snapshot),
            close: async () => {},
          };
          const result = await fn(snapshot);
          await client.query("COMMIT");
          return result;
        } catch (error) {
          await client.query("ROLLBACK");
          throw error;
        } finally {
          client.release();
        }
      },
      close: () => pool.end(),
    };
  }
  if (process.env.NODE_ENV === "production")
    throw new Error("DATABASE_URL is required in production.");
  const pg = new PGlite(
    options.memory
      ? undefined
      : options.dataDir || process.env.PGLITE_PATH || "./motorline-data",
  );
  await pg.waitReady;
  const transaction: Database["transaction"] = (fn) =>
    pg.transaction(async (client) => {
      const tx: Database = {
        query: (sql, values) => client.query(sql, values),
        transaction: async (callback) => callback(tx),
        readSnapshot: async (callback) => callback(tx),
        close: async () => {},
      };
      return fn(tx);
    });
  return {
    query: (sql, values) => pg.query(sql, values),
    transaction,
    readSnapshot: transaction,
    close: () => pg.close(),
  };
}
export async function migrate(db: Database) {
  const directory = fileURLToPath(new URL("../migrations/", import.meta.url));
  const files = (await readdir(directory))
    .filter((name) => /^\d+.*\.sql$/.test(name))
    .sort();
  const sql = (
    await Promise.all(files.map((name) => readFile(directory + name, "utf8")))
  ).join("\n");
  // PGlite's extended query protocol accepts a single statement. Split only outside SQL functions.
  const statements = sql
    .split(/;(?=(?:[^$]*\$\$[^$]*\$\$)*[^$]*$)/)
    .map((value) => value.trim())
    .filter(Boolean);
  await db.query(
    "CREATE TABLE IF NOT EXISTS installation_lock (id integer PRIMARY KEY, revision bigint NOT NULL DEFAULT 0)",
  );
  await db.query(
    "INSERT INTO installation_lock(id) VALUES (1) ON CONFLICT DO NOTHING",
  );
  await db.transaction(async (tx) => {
    for (const statement of statements) await tx.query(statement);
  });
}
export type RecordData = Record<string, any>;
export async function records(
  db: Database,
  org: string,
  kind: string,
  branch?: string,
): Promise<RecordData[]> {
  const result = await db.query(
    "SELECT data FROM records WHERE organization_id=$1 AND kind=$2" +
      (branch !== undefined ? " AND branch_id=$3" : "") +
      " ORDER BY created_at,id",
    branch === undefined ? [org, kind] : [org, kind, branch],
  );
  return result.rows.map((row) => row.data);
}
export async function getRecord(
  db: Database,
  org: string,
  kind: string,
  id: string,
): Promise<RecordData | undefined> {
  return (
    await db.query(
      "SELECT data FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3",
      [org, kind, id],
    )
  ).rows[0]?.data;
}
export async function putRecord(
  db: Database,
  org: string,
  kind: string,
  data: RecordData,
  branch = "",
) {
  await db.query(
    "INSERT INTO records(id,organization_id,branch_id,kind,data) VALUES($1,$2,$3,$4,$5) ON CONFLICT(organization_id,kind,id) DO UPDATE SET data=excluded.data,branch_id=excluded.branch_id",
    [data.id, org, branch, kind, JSON.stringify(data)],
  );
  return data;
}
