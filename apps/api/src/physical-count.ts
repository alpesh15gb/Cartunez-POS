import { getRecord, putRecord, records, type Database, type RecordData } from "./db.js";
import { adjust, allow, audit, fail, id, idempotent, integer, inventory, now, scoped, text, type Actor } from "./domain.js";

const counterRoles = ["owner", "manager", "inventory"];
async function baseline(db: Database, actor: Actor, productId: string, binId: string) {
  const { rows } = await db.query(
    "SELECT (SELECT count(*) FROM stock_ledger WHERE organization_id=$1 AND branch_id=$2 AND product_id=$3 AND bin_id=$4) AS revision, " +
    "COALESCE((SELECT quantity FROM stock WHERE organization_id=$1 AND branch_id=$2 AND product_id=$3 AND bin_id=$4),0) AS quantity",
    [actor.organizationId, actor.branchId, productId, binId]);
  return { revision: String(rows[0].revision), expected: Number(rows[0].quantity) };
}

export async function startCount(db: Database, actor: Actor, body: any) {
  allow(actor, counterRoles);
  const product = await scoped(db, actor, "product", body.productId);
  if (product.type === "service") fail("Select a stock part.");
  if (product.onlineOnly) fail(`${product.name} is online only (sold on the website) and has no shop stock to count.`);
  const bin = await scoped(db, actor, "location", body.binId);
  const fields = { productId: product.id, binId: bin.id, branchId: actor.branchId, startedBy: actor.id };
  return idempotent(db, actor, body.transactionId, { action: "count-start", ...fields }, async () =>
    putRecord(db, actor.organizationId, "stockCount", { id: id("count"), ...fields,
      ...await baseline(db, actor, product.id, bin.id), serialTracked: product.serialTracked === true,
      status: "counting", startedAt: now() }, actor.branchId));
}

async function unchanged(db: Database, actor: Actor, count: RecordData) {
  const current = await baseline(db, actor, count.productId, count.binId);
  if (current.revision !== count.revision || current.expected !== count.expected)
    fail("Stock moved after this count started. Discard this count and recount the bin.", 409);
  const product = await scoped(db, actor, "product", count.productId);
  if (product.type === "service" || (product.serialTracked === true) !== count.serialTracked)
    fail("The part's stock tracking changed. Discard this count and recount the bin.", 409);
}

export async function submitCount(db: Database, actor: Actor, body: any) {
  allow(actor, counterRoles);
  const count = await scoped(db, actor, "stockCount", body.countId);
  if (count.startedBy !== actor.id) fail("Only the person who started this count can enter the observation.", 403);
  const counted = integer(body.counted, "Counted units");
  const reason = text(body.reason, "count reason");
  const raw = body.serials ?? [];
  if (!Array.isArray(raw)) fail("Enter the serials found in the bin.");
  const serials: string[] = raw.map(serial => text(serial, "serial"));
  if (serials.length !== (count.serialTracked ? counted : 0) || new Set(serials).size !== serials.length)
    fail("Enter exactly one distinct serial for every counted serial-tracked unit.");
  const observation = { counted, reason, serials };
  return idempotent(db, actor, body.transactionId, { action: "count-submit", countId: count.id, actorId: actor.id, ...observation }, async () => {
    if (count.status !== "counting") fail("This count has already been submitted or discarded.", 409);
    await unchanged(db, actor, count);
    return putRecord(db, actor.organizationId, "stockCount", { ...count, ...observation,
      delta: counted - count.expected, status: "review", submittedAt: now() }, actor.branchId);
  });
}

async function reconcileSerials(db: Database, actor: Actor, count: RecordData, binKind: string) {
  const { rows } = await db.query(
    "SELECT data FROM records WHERE organization_id=$1 AND branch_id=$2 AND kind='serial' " +
    "AND data->>'productId'=$3 AND data->>'binId'=$4 AND data->>'status'=$5",
    [actor.organizationId, actor.branchId, count.productId, count.binId, binKind === "sellable" ? "available" : binKind]);
  const current = new Map<string, RecordData>(rows.map(({ data }) => [data.serial, data]));
  if (current.size !== count.expected) fail("The serial register and recorded quantity differ. Resolve the serial discrepancy before confirming.", 409);
  const observed = new Set<string>(count.serials);
  const removed = [...current.keys()].filter(serial => !observed.has(serial));
  const added = [...observed].filter(serial => !current.has(serial));
  const held = new Set<string>();
  for (const hold of await records(db, actor.organizationId, "hold", actor.branchId))
    for (const line of hold.cart.lines)
      if (line.productId === count.productId && line.binId === count.binId)
        for (const serial of line.serials ?? []) held.add(serial);
  if (removed.some(serial => held.has(serial))) fail("A missing serial belongs to a parked bill. Resolve its reservation before confirming.", 409);
  for (const serial of added) {
    const serialId = count.productId + ":" + serial;
    const prior = await getRecord(db, actor.organizationId, "serial", serialId);
    if (prior && !(prior.status === "adjusted-out" && prior.branchId === actor.branchId && prior.binId === count.binId))
      fail("Counted serial " + serial + " already belongs to another stock record or transaction.", 409);
    await putRecord(db, actor.organizationId, "serial", {
      id: serialId, branchId: actor.branchId, productId: count.productId, binId: count.binId, serial,
      status: binKind === "sellable" ? "available" : binKind,
    }, actor.branchId);
  }
  for (const serial of removed) {
    await putRecord(db, actor.organizationId, "serial", { ...current.get(serial)!, status: "adjusted-out" }, actor.branchId);
  }
  return { added, removed };
}

export async function confirmCount(db: Database, actor: Actor, body: any) {
  allow(actor, ["owner", "manager"]);
  if (!body.countId) fail("Start and submit a physical count before confirming it.");
  const count = await scoped(db, actor, "stockCount", body.countId);
  return idempotent(db, actor, body.transactionId, { action: "count-confirm", countId: count.id, reviewer: actor.id }, async () => {
    if (count.status === "confirmed") return count;
    if (count.status !== "review") fail("Submit the physical count for manager review first.", 409);
    await unchanged(db, actor, count);
    const bin = await scoped(db, actor, "location", count.binId);
    const stock = (await inventory(db, actor)).find(row => row.binId === count.binId && row.productId === count.productId);
    if (count.counted < (stock?.reserved ?? 0)) fail("The count would consume reserved stock. Resolve open reservations first.", 409);
    const serialChanges = count.serialTracked ? await reconcileSerials(db, actor, count, bin.kind) : { added: [], removed: [] };
    // Equal-quantity serial swaps must advance the same revision used to detect concurrent corrections.
    if (count.delta || serialChanges.added.length || serialChanges.removed.length)
      await adjust(db, actor, count.productId, count.binId, count.delta, count.reason, count.id);
    const confirmed = { ...count, status: "confirmed", confirmedAt: now(), confirmedBy: actor.id, serialChanges };
    await audit(db, actor, "stock-count", count.id, count.reason, {
      productId: count.productId, binId: count.binId, expected: count.expected, counted: count.counted,
      quantity: count.delta, revision: count.revision, startedBy: count.startedBy, serialChanges,
    });
    return putRecord(db, actor.organizationId, "stockCount", confirmed, actor.branchId);
  });
}

export async function discardCount(db: Database, actor: Actor, body: any) {
  allow(actor, counterRoles);
  const count = await scoped(db, actor, "stockCount", body.countId);
  if (actor.role === "inventory" && actor.id !== count.startedBy) fail("This count belongs to another counter.", 403);
  if (count.status === "discarded") return count;
  if (count.status === "confirmed") fail("A confirmed count is already recorded.", 409);
  return putRecord(db, actor.organizationId, "stockCount", { ...count, status: "discarded", discardedAt: now(), discardedBy: actor.id }, actor.branchId);
}
