import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { getRecord, putRecord } from "../db.js";
import {
  allow,
  scoped,
  integer,
  text,
  fail,
  id,
  now,
  adjust,
  audit,
  inventory,
  approved,
} from "../domain.js";
import { confirmCount, discardCount, startCount, submitCount } from "../physical-count.js";

export function inventoryRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("inventory/move", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const quantity = integer(body.quantity, "Quantity", 1);
    text(body.reason, "reason");
    const from = await scoped(tx, actor, "location", body.fromBinId),
      to = await scoped(tx, actor, "location", body.toBinId);
    if (from.id === to.id) fail("Choose a different destination bin.");
    if (from.kind !== to.kind)
      fail("Use an audited return or adjustment to change stock condition.");
    const stock = (await inventory(tx, actor)).find(
      (item) =>
        item.productId === body.productId && item.binId === body.fromBinId,
    );
    if (!stock || stock.available < quantity)
      fail("Movement would consume reserved or unavailable stock.", 409);
    const reference = id("move");
    await adjust(
      tx,
      actor,
      body.productId,
      body.fromBinId,
      -quantity,
      body.reason,
      reference,
    );
    await adjust(
      tx,
      actor,
      body.productId,
      body.toBinId,
      quantity,
      body.reason,
      reference,
    );
    const product = await scoped(tx, actor, "product", body.productId);
    if (product.serialTracked) {
      if (
        !Array.isArray(body.serials) ||
        body.serials.length !== quantity ||
        new Set(body.serials).size !== quantity
      )
        fail("Select one serial for each moved unit.");
      for (const serial of body.serials) {
        const item = await scoped(
          tx,
          actor,
          "serial",
          product.id + ":" + serial,
        );
        if ((item.status !== "available" && item.status !== from.kind) || item.binId !== body.fromBinId)
          fail("Serial is unavailable in the source bin.");
        await putRecord(
          tx,
          actor.organizationId,
          "serial",
          { ...item, binId: body.toBinId },
          actor.branchId,
        );
      }
    }
    await audit(tx, actor, "stock-move", reference, body.reason, body);
    return { id: reference };
  });
  post("inventory/count/start", startCount);
  post("inventory/count/submit", submitCount);
  post("inventory/count/discard", discardCount);
  post("inventory/count", confirmCount);
  post("inventory/adjust", async (tx, actor, body) => {
      allow(actor, ["owner", "manager", "inventory"]);
      text(body.reason, "reason");
      await approved(
        tx,
        actor,
        "adjustment",
        body.approvalId,
        body.transactionId || body.productId + body.binId,
        { amount: Math.abs(Number(body.quantity)), subjectId: body.productId }, // Security: bound approval
      );
      const stock = (await inventory(tx, actor)).find(
        (item) =>
          item.productId === body.productId && item.binId === body.binId,
      );
      const quantity = integer(body.quantity, "Adjustment", -1000000, 1000000);
      if ((stock?.available || 0) + quantity < 0)
        fail("Adjustment would consume reserved stock.", 409);
      const product = await scoped(tx, actor, "product", body.productId);
      if (product.type === "service") fail("Services do not carry stock.");
      if (product.onlineOnly) fail(`${product.name} is online only (sold on the website) and carries no shop stock.`);
      const bin = await scoped(tx, actor, "location", body.binId);
      const serialStatus = bin.kind === "sellable" ? "available" : bin.kind;
      const reference = id("adjust");
      await adjust(
        tx,
        actor,
        body.productId,
        body.binId,
        quantity,
        body.reason,
        reference,
      );
      if (product.serialTracked && quantity !== 0) {
        if (
          !Array.isArray(body.serials) ||
          body.serials.length !== Math.abs(quantity) ||
          new Set(body.serials).size !== Math.abs(quantity)
        )
          fail("Provide one serial for every adjusted unit.");
        for (const serial of body.serials) {
          text(serial, "serial");
          const serialId = product.id + ":" + serial;
          const existing = await getRecord(
            tx,
            actor.organizationId,
            "serial",
            serialId,
          );
          if (quantity > 0) {
            if (existing) fail("Serial already exists.");
            await putRecord(
              tx,
              actor.organizationId,
              "serial",
              {
                id: serialId,
                branchId: actor.branchId,
                productId: product.id,
                serial,
                binId: body.binId,
                status: serialStatus,
              },
              actor.branchId,
            );
          } else {
            if (
              !existing ||
              existing.branchId !== actor.branchId ||
              existing.binId !== body.binId ||
              (existing.status !== serialStatus && existing.status !== "available")
            )
              fail("Serial is unavailable in the counted bin.");
            await putRecord(
              tx,
              actor.organizationId,
              "serial",
              { ...existing, status: "adjusted-out" },
              actor.branchId,
            );
          }
        }
      }
      await audit(tx, actor, "stock-adjust", reference, body.reason, {
        ...body,
        quantity,
      });
      return { id: reference, quantity };
    });
}

export function transferRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("transfers", async (tx, actor, body) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const user = (await getRecord(tx, actor.organizationId, "user", actor.id))!;
    if (
      !user.branchIds.includes(body.destinationBranchId) ||
      body.destinationBranchId === actor.branchId
    )
      fail("Choose an authorized destination branch.", 403);
    text(body.reason, "transfer reason");
    if (!Array.isArray(body.lines) || !body.lines.length)
      fail("Add transfer lines.");
    const transferId = id("transfer");
    const lines = [];
    for (const input of body.lines) {
      const quantity = integer(input.quantity, "Transfer quantity", 1);
      const stock = (await inventory(tx, actor)).find(
        (item) =>
          item.productId === input.productId && item.binId === input.binId,
      );
      if (!stock || stock.available < quantity)
        fail("Insufficient available stock.", 409);
      const product = await scoped(tx, actor, "product", input.productId);
      const source = await scoped(tx, actor, "location", input.binId);
      if (source.kind !== "sellable")
        fail("Transfer available stock from a sellable bin.");
      if (product.serialTracked) {
        if (
          !Array.isArray(input.serials) ||
          input.serials.length !== quantity ||
          new Set(input.serials).size !== quantity
        )
          fail("Select a serial for each transferred unit.");
        for (const serial of input.serials) {
          const item = await scoped(
            tx,
            actor,
            "serial",
            product.id + ":" + serial,
          );
          if (item.status !== "available" || item.binId !== input.binId)
            fail("Serial is unavailable at source.");
          await putRecord(
            tx,
            actor.organizationId,
            "serial",
            { ...item, status: "in-transit", transferId },
            actor.branchId,
          );
        }
      }
      await adjust(
        tx,
        actor,
        input.productId,
        input.binId,
        -quantity,
        "Transfer dispatch",
        transferId,
      );
      lines.push({
        ...input,
        id: id("transfer-line"),
        quantity,
        received: 0,
        receivedSerials: [],
      });
    }
    const transfer = {
      id: transferId,
      branchId: actor.branchId,
      destinationBranchId: body.destinationBranchId,
      lines,
      reason: body.reason,
      status: "dispatched",
      createdAt: now(),
      userId: actor.id,
    };
    await audit(tx, actor, "transfer-dispatch", transferId, body.reason);
    return putRecord(
      tx,
      actor.organizationId,
      "transfer",
      transfer,
      actor.branchId,
    );
  });
  post("transfers/:id/receive", async (tx, actor, body, params) => {
    allow(actor, ["owner", "manager", "inventory"]);
    const transfer = await getRecord(
      tx,
      actor.organizationId,
      "transfer",
      params.id,
    );
    if (!transfer || transfer.destinationBranchId !== actor.branchId)
      fail("Transfer is unavailable in this branch.", 404);
    if (!Array.isArray(body.lines) || !body.lines.length)
      fail("Add receipt lines.");
    for (const input of body.lines) {
      const candidates = transfer.lines.filter((line: any) =>
        input.lineId
          ? line.id === input.lineId
          : line.productId === input.productId,
      );
      if (candidates.length !== 1) fail("Select the exact transfer line.");
      const line = candidates[0];
      const quantity = integer(
        input.quantity,
        "Receipt quantity",
        1,
        line.quantity - line.received,
      );
      const product = await scoped(tx, actor, "product", line.productId);
      const bin = await scoped(tx, actor, "location", input.binId);
      if (bin.kind !== "sellable")
        fail("Receive transfer into a sellable bin.");
      if (product.serialTracked) {
        if (
          !Array.isArray(input.serials) ||
          input.serials.length !== quantity ||
          new Set(input.serials).size !== quantity
        )
          fail("Scan each received serial.");
        for (const serial of input.serials) {
          const item = await getRecord(
            tx,
            actor.organizationId,
            "serial",
            product.id + ":" + serial,
          );
          if (
            !item ||
            !line.serials.includes(serial) ||
            line.receivedSerials.includes(serial) ||
            item.status !== "in-transit" ||
            item.transferId !== transfer.id
          )
            fail("Serial does not belong to the pending transfer.");
          await putRecord(
            tx,
            actor.organizationId,
            "serial",
            {
              ...item,
              branchId: actor.branchId,
              binId: bin.id,
              status: "available",
              transferId: null,
            },
            actor.branchId,
          );
          line.receivedSerials.push(serial);
        }
      }
      await adjust(
        tx,
        actor,
        line.productId,
        input.binId,
        quantity,
        "Transfer receipt",
        transfer.id,
      );
      line.received += quantity;
    }
    transfer.status = transfer.lines.every(
      (line: any) => line.quantity === line.received,
    )
      ? "received"
      : "partial";
    await audit(
      tx,
      actor,
      "transfer-receipt",
      transfer.id,
      "Transfer received",
    );
    return putRecord(
      tx,
      actor.organizationId,
      "transfer",
      transfer,
      transfer.branchId,
    );
  });
}
