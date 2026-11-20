// Product photos. Each photo is its own record (base64 in the database, so it
// is included in the existing backups). The app resizes photos before upload.
import type { FastifyInstance } from "fastify";
import type { Database } from "./db.js";
import { getRecord, putRecord } from "./db.js";
import { allow, fail, id, type Actor } from "./domain.js";
import { queueMagentoSync } from "./online-queue.js";
import type { Post } from "./routes/types.js";


const MAX_BYTES = 2_500_000;
const MAX_PHOTOS = 8;
const types: Record<string, (b: Buffer) => boolean> = {
  "image/jpeg": (b) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff,
  "image/png": (b) => b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
  "image/webp": (b) => b.subarray(0, 4).toString("ascii") === "RIFF" && b.subarray(8, 12).toString("ascii") === "WEBP",
};

/** Photo details without the image bytes, in display order. */
export async function productImages(db: Database, organizationId: string, productId?: string) {
  const rows = (
    await db.query(
      "SELECT data - 'data' AS data FROM records WHERE organization_id=$1 AND kind='productImage'" +
        (productId ? " AND data->>'productId'=$2" : ""),
      productId ? [organizationId, productId] : [organizationId],
    )
  ).rows.map((r: any) => r.data);
  return rows.sort((a: any, b: any) => a.productId.localeCompare(b.productId) || a.position - b.position);
}

/** One photo with its bytes (for Magento). */
export async function productImageData(db: Database, organizationId: string, imageId: string) {
  return getRecord(db, organizationId, "productImage", imageId);
}

async function renumber(db: Database, organizationId: string, productId: string, order: string[]) {
  const images = await productImages(db, organizationId, productId);
  const ids = [...order.filter((i) => images.some((m: any) => m.id === i)), ...images.map((m: any) => m.id).filter((i: string) => !order.includes(i))];
  for (const [position, imageId] of ids.entries()) {
    const full = await getRecord(db, organizationId, "productImage", imageId);
    if (full && full.position !== position) await putRecord(db, organizationId, "productImage", { ...full, position });
  }
}

export function productImageRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("products/:id/images", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const product = await getRecord(tx, actor.organizationId, "product", String(params.id));
    if (!product) fail("Part not found.", 404);
    const contentType = String(body.contentType || "");
    if (!types[contentType]) fail("Use a JPEG, PNG or WebP photo.");
    if (typeof body.data !== "string" || body.data.length > MAX_BYTES * 1.4) fail("The photo is too large (2.5 MB at most).");
    const bytes = Buffer.from(body.data, "base64");
    if (!bytes.length || bytes.length > MAX_BYTES) fail("The photo is too large (2.5 MB at most).");
    if (!types[contentType](bytes)) fail("That file is not a valid photo.");
    const existing = await productImages(tx, actor.organizationId, product!.id);
    if (existing.length >= MAX_PHOTOS) fail(`A part can have ${MAX_PHOTOS} photos at most.`);
    const image = {
      id: id("img"),
      productId: product!.id,
      contentType,
      size: bytes.length,
      width: Number(body.width) || null,
      height: Number(body.height) || null,
      position: existing.length,
      createdAt: new Date().toISOString(),
      userId: actor.id,
      data: bytes.toString("base64"),
    };
    await putRecord(tx, actor.organizationId, "productImage", image);
    await queueMagentoSync(tx, actor.organizationId, [product!.id], "photo");
    const { data, ...meta } = image;
    return meta;
  });

  // The first photo is the main one (shown in lists and as Magento's base image).
  post("products/:id/images/order", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    if (!Array.isArray(body.imageIds)) fail("Send the photos in the new order.");
    await renumber(tx, actor.organizationId, String(params.id), body.imageIds.map(String));
    await queueMagentoSync(tx, actor.organizationId, [String(params.id)], "photo");
    return productImages(tx, actor.organizationId, String(params.id));
  });

  app.delete("/api/v1/products/:id/images/:imageId", async (request: any) =>
    db.transaction(async (tx) => {
      const actor: Actor = request.actor;
      allow(actor, ["owner", "manager", "inventory"]);
      const image = await getRecord(tx, actor.organizationId, "productImage", String(request.params.imageId));
      if (!image || image.productId !== request.params.id) fail("Photo not found.", 404);
      await tx.query("DELETE FROM records WHERE organization_id=$1 AND kind='productImage' AND id=$2", [actor.organizationId, image!.id]);
      await renumber(tx, actor.organizationId, image!.productId, []);
      await queueMagentoSync(tx, actor.organizationId, [image!.productId], "photo");
      return { deleted: true };
    }),
  );

  app.get("/api/v1/product-images/:imageId", async (request: any, reply) => {
    const actor: Actor = request.actor;
    const image = await getRecord(db, actor.organizationId, "productImage", String(request.params.imageId));
    if (!image) fail("Photo not found.", 404);
    reply.header("Content-Type", image!.contentType);
    // Photo IDs never change, so browsers and apps may keep them.
    reply.header("Cache-Control", "private, max-age=31536000, immutable");
    return reply.send(Buffer.from(image!.data, "base64"));
  });
}
