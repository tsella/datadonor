'use strict';
/**
 * Energy out, per local day, from the watch only.
 *
 * Mirrors `meal_macros.out_kcal()` exactly: basal + active summed over the
 * watch's own rows, bucketed with the active timezone. Other sources (Oura,
 * StepsApp, the iPhone) write the same data types and double-count, so the
 * source filter is not optional.
 */
const cfg = require('../config');
const { all, text } = require('../db');
const time = require('../time');

const BASAL = 'HKQuantityTypeIdentifierBasalEnergyBurned';
const ACTIVE = 'HKQuantityTypeIdentifierActiveEnergyBurned';

/** Map of ISO day -> {basal, active, total, samples}. Days with no rows are absent. */
async function byDay(dd, off, from, to) {
  const mod = time.shiftMod(off);
  const rows = await all(
    dd,
    `SELECT date(start_date, ${mod}) AS d,
            SUM(CASE WHEN data_type = '${BASAL}'  THEN CAST(value AS REAL) ELSE 0 END) AS basal,
            SUM(CASE WHEN data_type = '${ACTIVE}' THEN CAST(value AS REAL) ELSE 0 END) AS active,
            COUNT(*) AS samples
       FROM health_metrics
      WHERE data_type IN ('${BASAL}', '${ACTIVE}')
        AND source LIKE ?
        AND date(start_date, ${mod}) BETWEEN ? AND ?
      GROUP BY d
      ORDER BY d`,
    [cfg.energySourceLike, from, to],
  );
  const map = new Map();
  for (const r of rows) {
    const basal = Number(r.basal) || 0;
    const active = Number(r.active) || 0;
    map.set(r.d, {
      basal,
      active,
      total: basal || active ? basal + active : null,
      samples: Number(r.samples) || 0,
    });
  }
  return map;
}

/**
 * Timestamp of the newest energy sample, as an ISO string, plus its age in
 * minutes. A day is only final once the phone has uploaded it, so this travels
 * with every response instead of being discovered by whoever reads a chart.
 */
async function lastSample(dd, now = new Date()) {
  const raw = await text(
    dd,
    `SELECT MAX(end_date) FROM health_metrics
      WHERE data_type = '${ACTIVE}' AND source LIKE ?`,
    [cfg.energySourceLike],
  );
  if (!raw) return { at: null, lag_minutes: null };
  const at = String(raw).replace(' ', 'T');
  const ms = Date.parse(at.endsWith('Z') ? at : `${at}Z`);
  const lag = Number.isFinite(ms) ? Math.round((now.getTime() - ms) / 60000) : null;
  return { at, lag_minutes: lag };
}

/** First and last local day the watch has energy for. */
async function coverage(dd, off) {
  const mod = time.shiftMod(off);
  const row = await all(
    dd,
    `SELECT MIN(date(start_date, ${mod})) AS first, MAX(date(start_date, ${mod})) AS last
       FROM health_metrics
      WHERE data_type IN ('${BASAL}', '${ACTIVE}') AND source LIKE ?`,
    [cfg.energySourceLike],
  );
  return row.length ? { first: row[0].first, last: row[0].last } : { first: null, last: null };
}

module.exports = { byDay, lastSample, coverage, BASAL, ACTIVE };
