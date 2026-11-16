export const developmentSecret =
  "development-only-motorline-please-change-secret";

export function runtimeConfig() {
  const production = process.env.NODE_ENV === "production";
  const jwtSecret = process.env.JWT_SECRET || developmentSecret;
  if (production) {
    if (!process.env.DATABASE_URL)
      throw new Error("DATABASE_URL is required in production.");
    if (process.env.SEED_DEMO === "true")
      throw new Error("Demo seeding is disabled in production.");
    if (
      jwtSecret.length < 32 ||
      /development|change.?me|please.?change|example|placeholder/i.test(
        jwtSecret,
      ) ||
      new Set(jwtSecret).size < 12
    ) {
      throw new Error(
        "JWT_SECRET must be a unique randomly generated secret of at least 32 characters.",
      );
    }
    const origins = (process.env.CORS_ORIGINS || "")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean);
    if (!origins.some((origin) => /^https:\/\/[^/]+$/.test(origin)))
      throw new Error(
        "CORS_ORIGINS must include the exact HTTPS shop origin in production.",
      );
  }
  const trustedProxyHops = Number(process.env.TRUST_PROXY_HOPS || 0);
  if (
    !Number.isInteger(trustedProxyHops) ||
    trustedProxyHops < 0 ||
    trustedProxyHops > 4
  )
    throw new Error("TRUST_PROXY_HOPS must be an integer from zero to four.");
  return { production, jwtSecret, trustedProxyHops };
}
