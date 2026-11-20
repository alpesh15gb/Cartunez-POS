import type { Database } from "./db.js";
import { getRecord, putRecord } from "./db.js";
import { hashPassword } from "./domain.js";
import { currencyCode, emailAddress } from "./settings.js";
import { SERIES_DEFAULTS } from "./number-series.js";
export async function bootstrapOwner(db: Database) {
  if (!process.env.BOOTSTRAP_OWNER_PASSWORD) return;
  const production = process.env.NODE_ENV === "production";
  const required = (name: string, developmentFallback: string) => {
    const value = process.env[name] || (production ? "" : developmentFallback);
    if (!value.trim())
      throw new Error(
        `${name} is required when creating a production organization.`,
      );
    return value.trim();
  };
  const org = required("BOOTSTRAP_ORG_ID", "shop");
  if (await getRecord(db, org, "organization", org)) return;
  if (
    process.env.BOOTSTRAP_OWNER_PASSWORD.length < 16 ||
    process.env.BOOTSTRAP_OWNER_PASSWORD.length > 256 ||
    (production &&
      /demo|change.?me|example|password123/i.test(
        process.env.BOOTSTRAP_OWNER_PASSWORD,
      ))
  )
    throw new Error(
      "BOOTSTRAP_OWNER_PASSWORD requires at least 16 characters.",
    );
  const branch = required("BOOTSTRAP_BRANCH_ID", "main");
  if (
    !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(org) ||
    !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(branch)
  )
    throw new Error(
      "Organization and branch codes must use lowercase letters, numbers, underscores, or hyphens.",
    );
  const email = emailAddress(
    required("BOOTSTRAP_OWNER_EMAIL", "owner@shop.local"),
  );
  const company = required("BOOTSTRAP_ORG_NAME", "My Shop");
  const branchName = required("BOOTSTRAP_BRANCH_NAME", "Main branch");
  const currency = currencyCode(required("BOOTSTRAP_CURRENCY", "INR"));
  await db.transaction(async (tx) => {
    if (await getRecord(tx, org, "organization", org)) return;
    await putRecord(tx, org, "organization", {
      id: org,
      name: company,
      currency,
    });
    await putRecord(tx, org, "branch", {
      id: branch,
      name: branchName,
      address: "",
    });
    await putRecord(tx, org, "settings", {
      id: "settings",
      currency,
      business: {
        legalName: "",
        tradingName: company,
        address: "",
        taxRegistrationId: "",
        phone: "",
        email: "",
        stateCode: "",
      },
      taxDisplayName: "Tax",
      taxMode: "exclusive",
      taxScheme: "general",
      localTaxName: "SGST",
      receiptFooter: "",
      tenderTypes: ["Cash", "Card", "UPI"],
      invoicePrefix: "INV",
      creditNotePrefix: "CR",
      nextCreditNote: 1,
      nextInvoice: 1,
      ...SERIES_DEFAULTS,
      nextDeviceNumber: 100000,
      offlineHours: 24,
      offlineTenders: ["Cash"],
      sessionHours: 8,
      cashierDiscountLimit: 0,
      roundingIncrement: 1,
      taxRates: [0, 500, 1200, 1800, 2800],
      // New shops start simple; owners can switch modules on in Settings.
      features: { transfers: false, fitment: false, offline: false, warranty: true },
    });
    await putRecord(tx, org, "user", {
      id: "owner",
      organizationId: org,
      name: process.env.BOOTSTRAP_OWNER_NAME || email,
      email,
      passwordHash: hashPassword(process.env.BOOTSTRAP_OWNER_PASSWORD!),
      role: "owner",
      branchIds: [branch],
      active: true,
    });
  });
}
