'use strict';
/**
 * Body mass per local day: the LAST reading of the day, plus the trailing
 * 7-day mean.
 *
 * Two things this provider exists to be honest about:
 *
 *  1. **No source filter by design.** `meal_macros.latest_weight()` takes the
 *     newest BodyMass row regardless of source, so the dashboard does the same
 *     or the numbers diverge. The source is carried on every reading instead,
 *     because there IS a seam: RENPHO Health stops on 2026-08-03 and Withings
 *     starts on 2026-08-06, and two different scales must not be averaged
 *     through a rolling window without saying so.
 *  2. **Days with no weigh-in are absent, not interpolated.** The 7-day mean is
 *     computed over the readings that exist, and how many days it actually
 *     covers travels with it (`n_days`), so a "7-day average" built from two
 *     readings cannot masquerade as a full week.
 */
const body = require('../db');
const time = require('../time');

const TYPE = 'HKQuantityTypeIdentifierBodyMass';

/** Map of ISO day -> {kg, source, at, n_days (trailing coverage)}. */
async function byDay(dd, off, from, to) {
  const mod = time.shiftMod(off);
  /* Pad the query 6 days before `from`: the trailing mean below looks back
     seven days, and without the pad the first days of every range would be
     averaged over a short window and disagree with the scripts' `weight_avg7`. */
  const fetchFrom = time.addDays(from, -6);
  /* ROW_NUMBER needs SQLite >= 3.25; the bundled driver is far newer. */
  const rows = await body.all(
    dd,
    `SELECT d, v, source, at FROM (
        SELECT date(start_date, ${mod}) AS d,
               CAST(value AS REAL) AS v,
               source,
               start_date AS at,
               ROW_NUMBER() OVER (
                 PARTITION BY date(start_date, ${mod})
                 ORDER BY start_date DESC
               ) AS rn
          FROM health_metrics
         WHERE data_type = '${TYPE}'
           AND date(start_date, ${mod}) BETWEEN ? AND ?
     ) WHERE rn = 1
     ORDER BY d`,
    [fetchFrom, to],
  );
  const map = new Map();
  for (const r of rows) {
    map.set(r.d, { kg: Number(r.v), source: r.source, at: r.at });
  }

  /* Trailing 7-day mean over existing readings only — no invented days. */
  const days = time.daysBetween(from, to);
  for (const day of days) {
    if (!map.has(day)) continue;
    let sum = 0;
    let n = 0;
    for (let i = 0; i < 7; i += 1) {
      const d = time.addDays(day, -i);
      const row = map.get(d);
      if (row && Number.isFinite(row.kg)) {
        sum += row.kg;
        n += 1;
      }
    }
    map.get(day).avg7 = n ? Number((sum / n).toFixed(2)) : null;
    map.get(day).n_days = n;
  }
  return map;
}

/** Newest reading at or before `day`, with its age in days (parity: latest_weight). */
async function latestAt(dd, off, day, maxAgeDays = 90) {
  const mod = time.shiftMod(off);
  const rows = await body.all(
    dd,
    `SELECT date(start_date, ${mod}) AS d, CAST(value AS REAL) AS v, source
       FROM health_metrics
      WHERE data_type = '${TYPE}'
        AND date(start_date, ${mod}) <= ?
      ORDER BY start_date DESC
      LIMIT 1`,
    [day],
  );
  if (!rows.length) return null;
  const age = time.rangeDays(rows[0].d, day) - 1;
  const stale = age > maxAgeDays;
  return { kg: stale ? null : Number(rows[0].v), day: rows[0].d, age_days: age, source: rows[0].source };
}

/** Per-source coverage, so the UI can mark the scale seam. */
async function sources(dd, off) {
  const mod = time.shiftMod(off);
  const rows = await body.all(
    dd,
    `SELECT source, COUNT(*) AS n,
            MIN(date(start_date, ${mod})) AS first,
            MAX(date(start_date, ${mod})) AS last
       FROM health_metrics
      WHERE data_type = '${TYPE}'
      GROUP BY source
      HAVING n > 5
      ORDER BY last DESC`,
  );
  return rows.map((r) => ({ source: r.source, n: Number(r.n), first: r.first, last: r.last }));
}

module.exports = { byDay, latestAt, sources, TYPE };
