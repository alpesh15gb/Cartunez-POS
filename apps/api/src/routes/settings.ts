import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, getRecord, putRecord } from "../db.js";
import { allow, integer, text, multiline, fail, audit } from "../domain.js";
import {
  currencyCode,
  businessProfile,
  invoiceProfile,
  gstProfile,
  documentNumber,
  labelLayout,
} from "../settings.js";

export function settingsRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("settings", async (tx, actor, body) => {
    allow(actor, ["owner"]);
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    if (body.currency !== undefined) {
      const currency = currencyCode(body.currency);
      if (currency !== settings.currency) {
        const monetary = await tx.query(
          "SELECT 1 FROM records WHERE organization_id=$1 AND kind IN ('invoice','purchaseOrder','purchaseReceipt','return','coreReturn','shift') LIMIT 1",
          [actor.organizationId],
        );
        if (monetary.rows.length)
          fail(
            "Currency cannot change after monetary records exist. Create a separate organization for another accounting currency.",
            409,
          );
      }
      settings.currency = currency;
    }
    if (body.invoicePrefix !== undefined)
      settings.invoicePrefix = text(
        body.invoicePrefix,
        "invoice prefix",
        true,
        24,
      );
    if (body.creditNotePrefix !== undefined)
      settings.creditNotePrefix = text(
        body.creditNotePrefix,
        "credit-note prefix",
        true,
        24,
      );
    if (body.business !== undefined)
      settings.business = {
        ...settings.business,
        ...businessProfile(body.business),
      };
    if (body.taxScheme !== undefined) {
      if (!["general", "india-gst"].includes(body.taxScheme))
        fail("Choose a supported tax scheme.");
      settings.taxScheme = body.taxScheme;
    }
    if (body.localTaxName !== undefined) {
      if (!["SGST", "UTGST"].includes(body.localTaxName))
        fail("Choose SGST or UTGST.");
      settings.localTaxName = body.localTaxName;
    }
    if (body.taxMode !== undefined) {
      if (!["inclusive", "exclusive"].includes(body.taxMode))
        fail("Choose inclusive or exclusive tax mode.");
      settings.taxMode = body.taxMode;
    }
    if (body.taxDisplayName !== undefined)
      settings.taxDisplayName = text(
        body.taxDisplayName,
        "tax display name",
        true,
        60,
      );
    if (body.receiptFooter !== undefined)
      settings.receiptFooter = multiline(body.receiptFooter, "receipt footer");
    if (body.tenderTypes !== undefined) {
      if (
        !Array.isArray(body.tenderTypes) ||
        !body.tenderTypes.length ||
        body.tenderTypes.some(
          (entry: any) => !["Cash", "Card", "UPI"].includes(entry),
        )
      )
        fail("Choose at least one supported tender.");
      settings.tenderTypes = [...new Set(body.tenderTypes)];
    }
    if (body.nextInvoice !== undefined) {
      const number = integer(
        body.nextInvoice,
        "Next invoice number",
        settings.nextInvoice,
        Number.MAX_SAFE_INTEGER - 100001,
      );
      const issued = await records(tx, actor.organizationId, "invoice");
      if (issued.some((invoice) => invoice.invoiceNumber === number))
        fail("That invoice number has already been issued.", 409);
      settings.nextInvoice = number;
    }
    const branch = (await getRecord(
      tx,
      actor.organizationId,
      "branch",
      actor.branchId,
    ))!;
    if (body.branchName !== undefined)
      branch.name = text(body.branchName, "branch name");
    if (body.branchAddress !== undefined)
      branch.address = multiline(body.branchAddress, "branch address");
    if (body.branchStateCode !== undefined)
      branch.stateCode = text(
        body.branchStateCode,
        "branch state code",
        false,
        50,
      );
    gstProfile(invoiceProfile(settings, branch));
    documentNumber(
      `${settings.invoicePrefix}-${branch.id.toUpperCase()}-${settings.nextInvoice}`,
      settings.taxScheme,
    );
    documentNumber(
      `${settings.creditNotePrefix || "CR"}-${branch.id.toUpperCase()}-${settings.nextCreditNote || 1}`,
      settings.taxScheme,
    );
    await putRecord(tx, actor.organizationId, "branch", branch);
    for (const [key, min, max] of [
      ["offlineHours", 0, 168],
      ["sessionHours", 1, 168],
      ["cashierDiscountLimit", 0, 1000000],
      ["roundingIncrement", 1, 10000],
    ] as const)
      if (body[key] !== undefined)
        settings[key] = integer(body[key], key, min, max);
    if (body.offlineTenders) {
      if (
        !Array.isArray(body.offlineTenders) ||
        body.offlineTenders.some((type: any) => !["Cash"].includes(type))
      )
        fail("Only cash is supported without provider confirmation.");
      settings.offlineTenders = body.offlineTenders;
    }
    if (body.features !== undefined) {
      if (!body.features || typeof body.features !== "object" || Array.isArray(body.features))
        fail("Choose which modules are switched on.");
      const features: Record<string, boolean> = { ...(settings.features || {}) };
      for (const [key, value] of Object.entries(body.features)) {
        if (!["transfers", "fitment", "offline", "warranty", "onlineStore", "negativeStock"].includes(key))
          fail("Unknown module.");
        if (typeof value !== "boolean") fail("Module switches must be on or off.");
        features[key] = value;
      }
      settings.features = features;
    }
    if (body.labelLayout !== undefined) {
      settings.labelLayout = labelLayout(body.labelLayout);
    }
    // WS-A: static UPI QR at the counter (upi://pay?pa=<upiVpa>&pn=<upiPayeeName>&am=...).
    if (body.upiVpa !== undefined) {
      const vpa = text(body.upiVpa, "UPI ID", false, 100).trim();
      if (vpa && !/^[A-Za-z0-9._-]{2,256}@[A-Za-z][A-Za-z0-9.-]{1,63}$/.test(vpa))
        fail("Enter the shop's UPI ID in the form name@bank, for example cartunez@okhdfcbank.");
      settings.upiVpa = vpa;
    }
    if (body.upiPayeeName !== undefined)
      settings.upiPayeeName = text(body.upiPayeeName, "UPI payee name", false, 60).trim();
    if (body.taxRates !== undefined) {
      if (
        !Array.isArray(body.taxRates) ||
        !body.taxRates.length ||
        body.taxRates.length > 100
      )
        fail("Provide between one and 100 tax rates.");
      settings.taxRates = body.taxRates.map((rate: any) =>
        integer(rate, "Tax rate", 0, 10000),
      );
    }
    await audit(
      tx,
      actor,
      "settings",
      "settings",
      "Configuration change",
      body,
    );
    return putRecord(tx, actor.organizationId, "settings", settings);
  });
}
