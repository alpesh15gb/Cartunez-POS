// Document number series kept on the settings record (estimates, job cards).
// Installs created before a series existed have no counter/prefix stored; the
// defaults below apply and are written back the first time a number is taken.
import type { Database, RecordData } from "./db.js";
import { getRecord, putRecord } from "./db.js";
import type { Actor } from "./domain.js";

export type NumberSeries = "estimate" | "job";

const SERIES: Record<NumberSeries, { counter: string; prefix: string; defaultPrefix: string }> = {
  estimate: { counter: "nextEstimate", prefix: "estimatePrefix", defaultPrefix: "EST" },
  job: { counter: "nextJob", prefix: "jobPrefix", defaultPrefix: "JOB" },
};

/** Defaults for new installs (see setup.ts). */
export const SERIES_DEFAULTS = {
  estimatePrefix: "EST",
  nextEstimate: 1,
  jobPrefix: "JOB",
  nextJob: 1,
};

/** The next number and prefix a series would issue, without taking it. */
export function peekNumber(settings: RecordData, series: NumberSeries) {
  const spec = SERIES[series];
  const next = Number.isSafeInteger(settings[spec.counter]) && settings[spec.counter] > 0
    ? settings[spec.counter]
    : 1;
  return { number: next as number, prefix: (settings[spec.prefix] as string) || spec.defaultPrefix };
}

/**
 * Takes the next number in a series and advances the counter. Call inside the
 * request transaction (the settings row is rewritten). Returns the sequence
 * number and the display number, e.g. "EST-PUNE-1".
 */
export async function nextNumber(db: Database, actor: Actor, series: NumberSeries) {
  const spec = SERIES[series];
  const settings = (await getRecord(db, actor.organizationId, "settings", "settings"))!;
  const { number, prefix } = peekNumber(settings, series);
  settings[spec.counter] = number + 1;
  if (!settings[spec.prefix]) settings[spec.prefix] = prefix;
  await putRecord(db, actor.organizationId, "settings", settings);
  return { number, display: `${prefix}-${actor.branchId.toUpperCase()}-${number}` };
}
