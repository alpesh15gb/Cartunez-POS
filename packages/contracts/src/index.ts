export type Role = "owner" | "manager" | "cashier" | "inventory";
export type FitmentStatus =
  "compatible" | "incompatible" | "universal" | "unverified";
export type Money = number; // Integer minor units, validated as safe integers at API boundary.
export interface Vehicle {
  id?: string;
  make: string;
  model: string;
  year: number;
  engine?: string;
  fuel?: string;
  trim?: string;
  drivetrain?: string;
  market?: string;
}
export interface SaleLine {
  productId: string;
  qty: number;
  binId: string;
  serials?: string[];
  overrideReason?: string;
}
export interface Tender {
  type: "Cash" | "Card" | "UPI";
  amount: Money;
  confirmed?: boolean;
  reference?: string;
}
export interface SaleInput {
  transactionId: string;
  deviceId?: string;
  invoiceNumber?: number;
  occurredAt?: string;
  offline?: boolean;
  customerId?: string;
  placeOfSupply?: string; // Domestic two-digit state code in india-gst mode.
  catalogRevision?: string;
  shiftId: string;
  vehicle?: Vehicle;
  priceLevel: "retail" | "wholesale";
  discount: Money;
  discountReason?: string;
  lines: SaleLine[];
  tenders: Tender[];
  approvalId?: string;
  discountApprovalId?: string;
}
export type TaxScheme = "general" | "india-gst";
export interface TaxComponent {
  name: string;
  rate: number;
  amount: Money;
}
export interface BusinessProfile {
  legalName: string;
  tradingName?: string;
  address: string;
  taxRegistrationId?: string;
  stateCode?: string;
  phone?: string;
  email?: string;
}
export interface ReceiptProfile {
  business: BusinessProfile;
  branch: { id: string; name: string; address: string; stateCode?: string };
  currency: string;
  taxMode: "inclusive" | "exclusive";
  taxScheme: TaxScheme;
  localTaxName: "SGST" | "UTGST";
  taxDisplayName: string;
  receiptFooter: string;
}
export interface CatalogAdapter {
  name: string;
  preview(
    input: string,
  ): Promise<{ rows: unknown[]; errors: { row: number; message: string }[] }>;
}
