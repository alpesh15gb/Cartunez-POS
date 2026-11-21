// Fresh-launch reset, run inside the API image against DATABASE_URL:
//   node apps/api/dist/reset-cli.js count [--org ID]
//   node apps/api/dist/reset-cli.js apply --org ID --confirm "CLEAR POS" [--reset-identity] [--gst-registered]
// deploy/cartunez/bin/reset-data.sh takes a backup and asks for confirmation first.
import { connectDatabase } from "./db.js";
import { organizations, resetCounts, resetForLaunch } from "./reset.js";

const args = process.argv.slice(2);
const command = args[0];
const option = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const flag = (name: string) => args.includes(name);

if (!["count", "apply"].includes(command || "")) {
  console.error('Usage: reset-cli.js count|apply [--org ID] [--confirm "CLEAR POS"] [--reset-identity] [--gst-registered]');
  process.exit(2);
}
if (!process.env.DATABASE_URL) {
  console.error("DATABASE_URL is required.");
  process.exit(2);
}
const db = await connectDatabase();
try {
  const orgs = await organizations(db);
  const org = option("--org") || (orgs.length === 1 ? orgs[0] : "");
  if (!org || !orgs.includes(org)) {
    console.error(`Choose the organization with --org (found: ${orgs.join(", ") || "none"}).`);
    process.exit(2);
  }
  if (command === "count") {
    console.log(JSON.stringify({ organization: org, ...(await resetCounts(db, org)) }));
  } else {
    if (option("--confirm") !== "CLEAR POS") {
      console.error('Refusing to reset without --confirm "CLEAR POS".');
      process.exit(2);
    }
    const result = await resetForLaunch(db, org, {
      keepIdentity: !flag("--reset-identity"),
      gstRegistered: flag("--gst-registered"),
      by: "reset-data.sh",
    });
    console.log(JSON.stringify({ organization: org, ...result }));
  }
} finally {
  await db.close();
}
