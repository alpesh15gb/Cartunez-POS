import { connectDatabase, migrate } from "./db.js";
import { seed } from "./seed.js";
import { bootstrapOwner } from "./setup.js";
const db = await connectDatabase();
await migrate(db);
if (process.argv[2] === "seed") await seed(db);
if (process.argv[2] === "setup") await bootstrapOwner(db);
await db.close();
console.log("Database operation completed.");
