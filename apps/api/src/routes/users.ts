import type { FastifyInstance } from "fastify";
import type { Database } from "../db.js";
import type { Post } from "./types.js";
import { records, getRecord, putRecord } from "../db.js";
import { allow, text, multiline, fail, id, hashPassword, audit } from "../domain.js";
import { emailAddress, invoiceProfile, gstProfile } from "../settings.js";
import { publicUser } from "./auth-pin.js"; // WS-D

const roles = ["owner", "manager", "cashier", "inventory"];

export function userRoutes(app: FastifyInstance, db: Database, post: Post) {
  post("users", async (tx, actor, body) => {
    allow(actor, ["owner"]);
    const users = await records(tx, actor.organizationId, "user");
    if (!roles.includes(body.role)) fail("Choose a valid role.");
    const email = emailAddress(body.email);
    if (
      users.some(
        (user) =>
          user.email.toLowerCase() === email.toLowerCase() &&
          user.id !== body.id,
      )
    )
      fail("Email is already registered.", 409);
    if (!Array.isArray(body.branchIds) || !body.branchIds.length)
      fail("Assign at least one branch.");
    for (const branchId of body.branchIds)
      if (!(await getRecord(tx, actor.organizationId, "branch", branchId)))
        fail("Unknown branch.");
    const existing = body.id
      ? await getRecord(tx, actor.organizationId, "user", body.id)
      : undefined;
    if (
      body.id === actor.id &&
      (body.active === false || body.role !== "owner")
    )
      fail("The active owner cannot remove their own access.");
    if (!existing || body.password) {
      if (
        typeof body.password !== "string" ||
        body.password.length < 12 ||
        body.password.length > 256
      )
        fail("Password requires between 12 and 256 characters.");
    }
    const user = {
      id: body.id || id("user"),
      organizationId: actor.organizationId,
      name: text(body.name, "name"),
      email,
      passwordHash: body.password
        ? hashPassword(body.password)
        : existing?.passwordHash,
      role: body.role,
      branchIds: body.branchIds,
      active: body.active !== false,
      authVersion: (existing?.authVersion || 0) + 1,
      // WS-D: keep the counter PIN; owners never sign in by PIN.
      ...(existing?.pinHash && body.role !== "owner" ? { pinHash: existing.pinHash } : {}),
    };
    await putRecord(tx, actor.organizationId, "user", user);
    await audit(tx, actor, "user-update", user.id, "User access management", {
      role: user.role,
      branches: user.branchIds,
    });
    return publicUser(user); // WS-D: no password or PIN hash
  });
  post("branches", async (tx, actor, body) => {
    allow(actor, ["owner"]);
    const branchId = text(body.id, "branch code", true, 64);
    if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(branchId))
      fail(
        "Branch code must use lowercase letters, numbers, hyphens, or underscores.",
      );
    const branch = {
      id: branchId,
      name: text(body.name, "branch name"),
      address: multiline(body.address || "", "branch address"),
      stateCode: text(body.stateCode || "", "state code", false, 50),
    };
    const settings = (await getRecord(
      tx,
      actor.organizationId,
      "settings",
      "settings",
    ))!;
    gstProfile(invoiceProfile(settings, branch));
    await putRecord(tx, actor.organizationId, "branch", branch);
    const owner = (await getRecord(
      tx,
      actor.organizationId,
      "user",
      actor.id,
    ))!;
    if (!owner.branchIds.includes(branchId)) {
      owner.branchIds.push(branchId);
      await putRecord(tx, actor.organizationId, "user", owner);
    }
    await audit(tx, actor, "branch", branchId, "Branch configuration updated");
    return branch;
  });
}
