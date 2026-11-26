import { getRecord, putRecord, type Database, type RecordData } from "./db.js";
import { roundRatio } from "./domain.js";
import { queueMagentoSync } from "./online-queue.js";

/** Split freight less discount by goods value, or by unit count for free goods. */
export function landedLineTotals(lines: RecordData[], otherCharges: number, discount: number) {
  const amounts = lines.map(line => line.quantity * line.cost);
  const subtotal = amounts.reduce((sum, amount) => sum + amount, 0);
  const spread = Math.max(-subtotal, otherCharges - discount);
  const weight = subtotal || lines.reduce((sum, line) => sum + line.quantity, 0);
  let cumulative = 0, allocated = 0;
  return lines.map((line, index) => {
    cumulative += subtotal ? amounts[index] : line.quantity;
    const next = roundRatio(spread, cumulative, weight);
    const total = amounts[index] + next - allocated;
    allocated = next;
    return total;
  });
}

const fields = ["cost", "lastPurchaseCost", "retailPrice"] as const;
type Field = typeof fields[number];
type Values = Record<Field, number | null>;
type Owners = Partial<Record<Field, string>>;

export type BillEconomics = {
  productId: string;
  before: Values;
  after: Values;
  previousOwners: Owners;
};

export const productValues = (part: RecordData): Values => ({
  cost: part.cost ?? null,
  lastPurchaseCost: part.lastPurchaseCost ?? null,
  retailPrice: part.retailPrice ?? null,
});

async function loadOwners(db: Database, org: string, productId: string): Promise<Owners> {
  return (await getRecord(db, org, "billEconomicsOwner", productId))?.fields ?? {};
}
const saveOwners = (db: Database, org: string, id: string, fields: Owners) =>
  putRecord(db, org, "billEconomicsOwner", { id, fields });

export async function captureBillEconomics(db: Database, org: string, part: RecordData): Promise<BillEconomics> {
  const values = productValues(part);
  return { productId: part.id, before: values, after: values, previousOwners: await loadOwners(db, org, part.id) };
}

export async function claimBillEconomics(db: Database, org: string, billId: string, snapshot: BillEconomics, wroteRetailPrice: boolean) {
  const owners = { ...snapshot.previousOwners, cost: billId, lastPurchaseCost: billId };
  if (wroteRetailPrice) owners.retailPrice = billId;
  await saveOwners(db, org, snapshot.productId, owners);
}

/** A subsequent goods receipt or manual edit supersedes just the fields it wrote. */
export async function supersedeBillEconomics(db: Database, org: string, productId: string, changed: readonly Field[]) {
  if (!changed.length) return;
  const owners = await loadOwners(db, org, productId);
  if (!changed.some(field => owners[field])) return;
  for (const field of changed) delete owners[field];
  await saveOwners(db, org, productId, owners);
}

export async function restoreBillEconomics(db: Database, org: string, bill: RecordData) {
  const documents = new Map<string, RecordData | undefined>();
  const priceChanges: string[] = [];
  for (const snapshot of (bill.productEconomics ?? []) as BillEconomics[]) {
    const owners = await loadOwners(db, org, snapshot.productId);
    const part = await getRecord(db, org, "product", snapshot.productId);
    if (!part) continue;
    let changed = false;
    for (const field of fields) {
      if (owners[field] !== bill.id) continue;
      delete owners[field];
      changed = true;
      if ((part[field] ?? null) !== snapshot.after[field]) continue;
      let source = snapshot;
      let prior = source.previousOwners[field];
      // If older bills were cancelled first, walk back to the last surviving value.
      while (prior) {
        if (!documents.has(prior)) documents.set(prior, await getRecord(db, org, "purchaseBill", prior));
        const previousBill = documents.get(prior);
        if (!previousBill?.voided) break;
        const previous = previousBill.productEconomics.find((s: BillEconomics) => s.productId === part.id);
        if (!previous || previous.after[field] !== source.before[field]) break;
        source = previous;
        prior = source.previousOwners[field];
      }
      if (prior) owners[field] = prior;
      if (field === "retailPrice" && part[field] !== source.before[field]) priceChanges.push(part.id);
      if (source.before[field] == null) delete part[field];
      else part[field] = source.before[field];
    }
    if (changed) {
      await putRecord(db, org, "product", part);
      await saveOwners(db, org, part.id, owners);
    }
  }
  if (priceChanges.length) await queueMagentoSync(db, org, priceChanges, "Supplier bill selling price reversed");
}
