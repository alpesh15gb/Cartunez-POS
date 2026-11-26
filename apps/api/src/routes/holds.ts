import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { getRecord, putRecord, records } from "../db.js";
import { allow, scoped, integer, text, fail, id, now, inventory, holdReserves, pickAvailability, reservedSerialIds, ONLINE_ONLY_MESSAGE } from "../domain.js";
import { isKit, reserveKitComponents } from "../hooks/kit-reserve.js";
import { queueMagentoSync } from "../online-queue.js";

/** Vehicle registration as printed on Indian plates, stored without spaces: "MH 12 AB 1234" -> "MH12AB1234". */
export function registrationNumber(value: unknown): string {
  if (value === undefined || value === null || value === "") return "";
  const plate = text(value, "vehicle registration number", false, 20)
    .toUpperCase()
    .replace(/[\s-]/g, "");
  if (plate && !/^[A-Z0-9]{4,12}$/.test(plate))
    fail("Enter the vehicle registration number with letters and digits only, for example MH12AB1234.");
  return plate;
}

/** Optional expiry for a parked sale: a date-time later than now and at most 30 days ahead. */
function expiry(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  const at = typeof value === "string" ? Date.parse(value) : NaN;
  if (!Number.isFinite(at)) fail("Enter a valid expiry date for the parked sale.");
  if (at <= Date.now()) fail("The parked sale's expiry must be in the future.");
  if (at > Date.now() + 30 * 24 * 3600 * 1000) fail("A parked sale can be kept for at most 30 days.");
  return new Date(at).toISOString();
}

/**
 * Parked sales (holds): the whole cart is saved with a label, the customer's
 * name and the vehicle registration so the counter can find it again by any of
 * them. Parked lines reserve their stock until resumed or discarded.
 * WS-A: moved here from routes/sales.ts and given label / customerName / regNo / expiresAt.
 */
export function holdRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("holds", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "cashier"]);
    const cart = body.cart;
    if (
      !Array.isArray(cart?.lines) ||
      !cart.lines.length ||
      cart.lines.length > 200
    )
      fail("Park between one and 200 cart lines.");
    const previous = body.id
      ? await scoped(tx, actor, "hold", body.id)
      : undefined;
    // Integration: job-card reservations are changed from the job card only.
    if (previous?.jobId) fail("These parts are reserved for a job card. Change them from the job card.", 409);
    const label = body.label === undefined ? previous?.label || "" : text(body.label, "label for the parked sale", false, 60).trim();
    const customerName =
      body.customerName === undefined
        ? previous?.customerName || ""
        : text(body.customerName, "customer name", false, 80).trim();
    const regNo = body.regNo === undefined ? previous?.regNo || "" : registrationNumber(body.regNo);
    const expiresAt = body.expiresAt === undefined ? previous?.expiresAt || null : expiry(body.expiresAt);
    const stock = await inventory(tx, actor);
    const ownLines = previous && holdReserves(previous) ? previous.cart?.lines : undefined;
    const pick = (productId: string, binId: string) => pickAvailability(stock, ownLines, productId, binId);
    const settings = await getRecord(tx, actor.organizationId, "settings", "settings");
    const negativeStock = settings?.features?.negativeStock !== false;
    const quantities = new Map<string, number>();
    let claimedSerials: Set<string> | undefined;
    const kitLines: { line: any; product: any }[] = [];
    for (const line of cart.lines) {
      const quantity = integer(line.qty, "Quantity", 1, 9999);
      line.qty = quantity;
      // Kit reservations are worked out here, never taken from the register.
      delete line.components;
      const product = await scoped(tx, actor, "product", line.productId);
      if (line.serials != null && !Array.isArray(line.serials)) fail("Serial numbers must be a list.");
      if (line.serials?.length) {
        if (!product.serialTracked || line.serials.length > quantity) fail("Choose at most one serial per tracked unit.");
        claimedSerials ??= await reservedSerialIds(tx, actor, previous?.id);
        line.serials = line.serials.map((value: unknown) => text(value, "serial number", true, 100));
        for (const serial of line.serials) {
          const key = product.id + ":" + serial;
          if (claimedSerials.has(key)) fail(`Serial ${serial} is already reserved.`, 409);
          const item = await scoped(tx, actor, "serial", key);
          if (item.status !== "available" || item.binId !== line.binId)
            fail(`Serial ${serial} is unavailable in the picked bin.`, 409);
          claimedSerials.add(key);
        }
      }
      if (product.salesStopped) fail("New sales are stopped for " + product.sku + ".", 409);
      if (product.onlineOnly) fail(`${product.name}: ${ONLINE_ONLY_MESSAGE}. It cannot be parked at the counter.`, 409);
      if (isKit(product)) kitLines.push({ line, product });
      if (product.type === "service") continue;
      const bin = await scoped(tx, actor, "location", line.binId);
      if (bin.kind !== "sellable") fail("Park stock from a sellable bin.");
      const key = line.productId + "|" + line.binId;
      quantities.set(key, (quantities.get(key) || 0) + quantity);
      const binStock = pick(product.id, bin.id);
      if (binStock.free < quantities.get(key)! && (!negativeStock || product.serialTracked || binStock.reservedByOthers))
        fail("Insufficient stock to park this bill.", 409);
    }
    // Money and stock review: a parked kit reserves its stocked components in bins.
    if (kitLines.length) {
      const bins = (await records(tx, actor.organizationId, "location", actor.branchId))
        .filter((bin) => bin.kind === "sellable")
        .map((bin) => bin.id);
      const taken = new Map(quantities);
      for (const { line, product } of kitLines)
        line.components = await reserveKitComponents(tx, actor, product, line.qty, {
          pick, taken, bins, sellBeyondStock: negativeStock,
        });
    }
    const hold = {
      id: previous?.id || id("hold"),
      branchId: actor.branchId,
      userId: actor.id,
      cart,
      label,
      customerName,
      regNo,
      expiresAt,
      createdAt: previous?.createdAt || now(),
      updatedAt: now(),
    };
    const savedHold = await putRecord(tx, actor.organizationId, "hold", hold, actor.branchId);
    // Parked sales hold stock, so the website shows less.
    await queueMagentoSync(
      tx,
      actor.organizationId,
      [...cart.lines, ...(previous?.cart.lines || [])].map((line: any) => line.productId),
      "hold",
      actor.branchId,
    );
    return savedHold;
  });
  app.delete("/api/v1/holds/:id", async (request: any) =>
    db.transaction(async (tx) => {
      const actor = request.actor;
      allow(actor, ["owner", "manager", "cashier"]);
      const released = await scoped(tx, actor, "hold", request.params.id);
      if (released.jobId) fail("These parts are reserved for a job card. Remove them from the job card or cancel the job.", 409);
      await queueMagentoSync(
        tx,
        actor.organizationId,
        (released.cart?.lines || []).map((line: any) => line.productId),
        "hold",
        actor.branchId,
      );
      await tx.query(
        "DELETE FROM records WHERE organization_id=$1 AND kind=$2 AND id=$3",
        [actor.organizationId, "hold", request.params.id],
      );
      return { deleted: true };
    }),
  );
}
