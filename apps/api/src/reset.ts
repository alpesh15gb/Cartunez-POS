// Fresh launch: clears the test data of one organization in a single transaction.
//
// Keeps: the organization and branch records, owner user accounts, bins/locations,
// customers and suppliers (opening balances set to 0, vehicle links cleared), and the
// Magento connection (settings.integrations.magento + integrationSecret "magento").
// Settings return to a new shop's defaults, keeping the business identity (shop name,
// address, phone...) unless asked not to; all number series restart at 1.
// Everything else goes: parts, stock, the stock ledger, idempotency records, invoices,
// returns, shifts, cash movements, purchasing, jobs, online listings/orders/queues,
// devices, and the audit trail (one audit entry records the reset).
//
// Run on the server by deploy/cartunez/bin/reset-data.sh through reset-cli.ts.
import type { Database } from "./db.js";
import { getRecord, putRecord } from "./db.js";
import { id, now } from "./domain.js";
import { defaultSettings } from "./setup.js";

/** Record kinds that survive the reset (users: owners only). */
export const KEPT_KINDS = ["organization", "branch", "user", "location", "customer", "supplier", "settings", "integrationSecret"];

export type ResetOptions = {
  /** Keep the shop name, legal name, address, phone, email, state, UPI and number prefixes (default true). */
  keepIdentity?: boolean;
  /** GST registered after the reset? Default false: "Not GST registered". */
  gstRegistered?: boolean;
  /** Who ran it, for the audit entry. */
  by?: string;
};

export type ResetCounts = {
  delete: Record<string, number>;
  keep: Record<string, number>;
};

// The user's own record says it is an owner.
const ownerSql = "(kind='user' AND data->>'role'='owner')";
const keptSql =
  `(kind IN ('organization','branch','location','customer','supplier','settings') OR ${ownerSql} OR (kind='integrationSecret' AND id='magento'))`;

/** What a reset would delete and keep, by record kind plus the stock tables. */
export async function resetCounts(db: Database, org: string): Promise<ResetCounts> {
  const rows = (await db.query(
    `SELECT kind, ${keptSql} AS kept, count(*)::int AS n FROM records WHERE organization_id=$1 GROUP BY kind, kept ORDER BY kind`,
    [org],
  )).rows;
  const result: ResetCounts = { delete: {}, keep: {} };
  for (const row of rows) {
    const side = row.kept ? result.keep : result.delete;
    const label = row.kind === "user" ? (row.kept ? "user (owner)" : "user (staff)") : row.kind;
    side[label] = (side[label] || 0) + Number(row.n);
  }
  for (const table of ["stock", "stock_ledger", "transactions"]) {
    const n = Number((await db.query(`SELECT count(*)::int AS n FROM ${table} WHERE organization_id=$1`, [org])).rows[0].n);
    if (n) result.delete[`table ${table}`] = n;
  }
  return result;
}

/** The organizations on this installation (a reset needs exactly one, or an explicit choice). */
export async function organizations(db: Database): Promise<string[]> {
  return (await db.query("SELECT id FROM records WHERE kind='organization' ORDER BY id")).rows.map((row) => row.id);
}

export async function resetForLaunch(db: Database, org: string, options: ResetOptions = {}) {
  const keepIdentity = options.keepIdentity !== false;
  return db.transaction(async (tx) => {
    const organization = await getRecord(tx, org, "organization", org);
    if (!organization) throw new Error(`Organization ${org} was not found.`);
    const owners = (await tx.query(
      `SELECT id FROM records WHERE organization_id=$1 AND ${ownerSql} AND COALESCE(data->>'active','true')<>'false'`,
      [org],
    )).rows;
    if (!owners.length) throw new Error("No active owner account would remain. Nothing was changed.");
    const before = await resetCounts(tx, org);
    const old = (await getRecord(tx, org, "settings", "settings")) || {};

    // Issued invoices, credit notes, audit entries, cash movements, the stock ledger
    // and idempotency records are protected by append-only triggers. They are switched
    // off only inside this transaction; a failure rolls the switch back with the data.
    for (const table of ["records", "stock_ledger", "transactions"])
      await tx.query(`ALTER TABLE ${table} DISABLE TRIGGER USER`);

    await tx.query(`DELETE FROM records WHERE organization_id=$1 AND NOT ${keptSql}`, [org]);
    for (const table of ["stock", "stock_ledger", "transactions"])
      await tx.query(`DELETE FROM ${table} WHERE organization_id=$1`, [org]);

    // Customers and suppliers start with no old balance and no links to deleted records.
    await tx.query(
      `UPDATE records SET data = (data - 'vehicleIds' - 'vehicleId' - 'garageId' - 'lastInvoiceId')
         || jsonb_build_object('openingBalance', 0, 'openingDate', '', 'vehicle', null)
       WHERE organization_id=$1 AND kind IN ('customer','supplier')`,
      [org],
    );

    // Settings: a new shop's defaults, the Magento connection, optionally the identity.
    const fresh = defaultSettings(old.currency || organization.currency || "INR", String(old.business?.tradingName || organization.name || ""));
    if (keepIdentity) {
      const business = old.business || {};
      fresh.business = {
        ...fresh.business,
        ...Object.fromEntries(
          ["legalName", "tradingName", "address", "phone", "email", "stateCode"]
            .filter((key) => business[key] !== undefined)
            .map((key) => [key, business[key]]),
        ),
        // Not GST registered: the GSTIN is cleared; enter it again when registering.
        taxRegistrationId: options.gstRegistered ? String(business.taxRegistrationId || "") : "",
      };
      for (const key of ["invoicePrefix", "creditNotePrefix", "estimatePrefix", "jobPrefix", "receiptFooter", "upiVpa", "upiPayeeName", "labelLayout"])
        if (old[key] !== undefined) fresh[key] = old[key];
    }
    // Module switches decide which screens the shop sees; keep them.
    if (old.features) fresh.features = old.features;
    fresh.taxScheme = options.gstRegistered ? "india-gst" : "none";
    if (old.integrations?.magento) {
      const magento = { ...old.integrations.magento };
      // Orders placed on the website before the launch are not read in.
      if (magento.enabled) magento.connectedAt = now();
      fresh.integrations = { magento };
    }
    await putRecord(tx, org, "settings", fresh);

    for (const table of ["records", "stock_ledger", "transactions"])
      await tx.query(`ALTER TABLE ${table} ENABLE TRIGGER USER`);

    // The one audit entry left: what this reset did.
    const branch = (await tx.query("SELECT id FROM records WHERE organization_id=$1 AND kind='branch' ORDER BY id LIMIT 1", [org])).rows[0]?.id || "";
    await putRecord(tx, org, "audit", {
      id: id("audit"),
      branchId: branch,
      userId: owners[0].id,
      action: "reset",
      subject: "organization",
      reason: "Fresh launch: test data cleared",
      details: { by: options.by || "reset-data.sh", keepIdentity, gstRegistered: !!options.gstRegistered, deleted: before.delete },
      createdAt: now(),
    }, branch);
    return { deleted: before.delete, kept: (await resetCounts(tx, org)).keep };
  });
}
