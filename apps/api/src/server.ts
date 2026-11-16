import { connectDatabase, migrate, records, putRecord } from "./db.js";
import { createApp } from "./app.js";
import { seed } from "./seed.js";
import { bootstrapOwner } from "./setup.js";
import { runtimeConfig } from "./config.js";
runtimeConfig();
const db = await connectDatabase();
await migrate(db);
if (process.env.SEED_DEMO === "true") await seed(db);
await bootstrapOwner(db);
const app = await createApp(db);
await app.listen({
  port: Number(process.env.PORT || 4000),
  host: process.env.HOST || "0.0.0.0",
});
console.log(`Motorline API listening on ${process.env.PORT || 4000}`);
const shutdown = async () => {
  await app.close();
  await db.close();
  process.exit(0);
};
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
