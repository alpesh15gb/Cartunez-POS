// Shapes used by the checkout pipeline (see sales.ts / sale-pipeline.ts).
//
// Invoices and their lines are stored as JSON in the `records` table, so every
// field added here is optional and additive: invoices written before a field
// existed simply do not carry it, and readers apply the documented default.
import type { Database, RecordData } from "./db.js";
import type { Actor } from "./domain.js";

/** What a line represents. Absent on stored lines: derive it with `lineKind`. */
export type LineKind = "part" | "service" | "kit" | "labour" | "returnRef";

/** Where the sale was made. Absent on stored invoices means "counter". */
export type SaleChannel = "counter" | "online";

/** Tender types the checkout recognises. Settings decide which drawer tenders are enabled. */
export const DRAWER_TENDERS = ["Cash", "Card", "UPI"] as const;
/** "Credit" = sold on the customer's account (udhaar). */
export const ACCOUNT_TENDERS = ["Credit", "Advance"] as const;
export const KNOWN_TENDERS = [...DRAWER_TENDERS, ...ACCOUNT_TENDERS] as const;
export type TenderType = (typeof KNOWN_TENDERS)[number];

/** One component of a kit line (filled by a future kit-expansion hook). */
export interface KitComponent {
  productId: string;
  sku?: string;
  qty: number;
  binId?: string;
  serials?: string[];
}

/** A line as sent by the register. */
export interface SaleLineInput {
  productId: string;
  qty: number;
  binId?: string;
  serials?: string[];
  overrideReason?: string;
  /** Who sold or fitted this line. Recorded only (no commission). */
  staffId?: string;
  [key: string]: any;
}

/** A priced invoice line as persisted. */
export interface SaleLine {
  id: string;
  productId: string;
  sku: string;
  name: string;
  hsnSac: string;
  unit: string;
  category: string;
  supplierId: string;
  qty: number;
  binId: string;
  serials: string[];
  unitPrice: number;
  cost: number;
  taxRate: number;
  coreCharge: number;
  subtotal: number;
  fitment: any;
  overrideReason: string;
  /** Product type ("part", "service", ...) copied from the product. */
  type: string;
  // Filled by the totals stage.
  discount?: number;
  tax?: number;
  taxMode?: string;
  taxComponents?: any[];
  total?: number;
  rounding?: number;
  // Optional additive fields.
  /** Default: derived from `type` (see `lineKind`). */
  kind?: LineKind;
  /** User id of the staff member who sold/fitted the line. Record only. */
  staffId?: string;
  /** Kit component lines. */
  components?: KitComponent[];
  [key: string]: any;
}

export interface SaleTender {
  type: string;
  amount: number;
  confirmed: boolean;
  reference: string;
}

/** The invoice record as persisted (only the fields the pipeline relies on are typed). */
export interface InvoiceDraft extends RecordData {
  id: string;
  branchId: string;
  number: string;
  invoiceNumber: number;
  lines: SaleLine[];
  subtotal: number;
  discount: number;
  tax: number;
  total: number;
  tenders: SaleTender[];
  // Optional additive fields.
  /** Default "counter". */
  channel?: SaleChannel;
  /** Job card the sale bills. */
  jobId?: string;
  /** Customer vehicle record the sale is for. */
  vehicleId?: string;
  /** Amount of customer advance applied to this invoice (paise). */
  advanceApplied?: number;
}

/** Shared state handed to every hook. Hooks may read anything and mutate lines/tenders/invoice. */
export interface SaleContext {
  db: Database;
  actor: Actor;
  /** The raw checkout request body. */
  body: any;
  /** True when a manager accepts an offline sync conflict. */
  reconcile: boolean;
  /** Live settings record. */
  currentSettings: RecordData;
  /** Settings in force for the sale (offline snapshot settings for offline sales). */
  settings: RecordData;
  branch: RecordData | undefined;
  /** Invoice/tax profile (see settings.invoiceProfile). */
  profile: any;
  shift: RecordData;
  hold: RecordData | undefined;
  /** Offline catalog snapshot, when body.offline. */
  catalog: any;
  stock: any[];
  sellBeyondStock: boolean;
  customer: RecordData | null;
  placeOfSupply: string;
  lines: SaleLine[];
  tenders: SaleTender[];
  requiresFitmentApproval: boolean;
  subtotal: number;
  coreTotal: number;
  discount: number;
  tax: number;
  rounding: number;
  total: number;
  /** Set after numbering; persisted after beforePersist. */
  invoice?: InvoiceDraft;
  /** Scratch space for hooks to pass data between their own stages. */
  state: Record<string, any>;
}

type Maybe<T> = T | Promise<T>;

/**
 * A checkout extension. Every method is optional; hooks run in registration
 * order within each stage. Throw via `fail()` to reject the sale.
 *
 * Stages, in order:
 *  1. validateLine   - once per input line, after the core line is priced and stock-checked
 *  2. expandLines    - add/replace lines (e.g. kit components) before totals
 *  3. (core totals, discount approval, rounding)
 *  4. validateTenders - after tenders are normalised, before coverage check
 *  5. (core numbering and invoice draft)
 *  6. beforePersist  - may amend ctx.invoice before it is written
 *  7. (invoice written)
 *  8. afterPersist   - side effects: stock, serials, warranty, audit
 */
export interface SaleHook {
  name: string;
  /** Tender types this hook makes acceptable (account-style tenders, not drawer money). */
  tenderTypes?: string[];
  validateLine?(ctx: SaleContext, input: SaleLineInput, line: SaleLine): Maybe<void>;
  expandLines?(ctx: SaleContext): Maybe<void>;
  validateTenders?(ctx: SaleContext): Maybe<void>;
  beforePersist?(ctx: SaleContext): Maybe<void>;
  afterPersist?(ctx: SaleContext): Maybe<void>;
}

const kinds: Record<string, LineKind> = { service: "service", kit: "kit", labour: "labour" };
/** The line's kind, falling back to the product type for lines stored without one. */
export function lineKind(line: { kind?: LineKind; type?: string }): LineKind {
  return line.kind || kinds[line.type || ""] || "part";
}
/** The invoice channel, defaulting to the counter. */
export function invoiceChannel(invoice: { channel?: SaleChannel }): SaleChannel {
  return invoice.channel || "counter";
}
