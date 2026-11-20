import type { Database } from "../db.js";
import type { Actor } from "../domain.js";

/** Registers a transactional POST route under /api/v1/ (see createApp in app.ts). */
export type Post = (
  path: string,
  handler: (db: Database, actor: Actor, body: any, params: any) => Promise<any>,
) => unknown;
