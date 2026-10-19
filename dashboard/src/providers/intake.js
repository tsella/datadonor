'use strict';
/**
 * The food tracker (`health_log.sqlite`): what was eaten, and what the day was
 * planned at. Two separate ideas that both live per local day:
 *
 *   intake  — what actually went in (sum of `meal_log`)
 *   target  — the plan issued that morning (`daily_targets`), plus the EOD's
 *             own measured totals once the day was finalised
 *
 * The dashboard reads both and never recomputes either: the meal scripts own
 * that math, and a second implementation here would disagree with the
 * the daily report reports within a week.
 */
const { all } = require('../db');

/** Map of ISO day -> {kcal, p, c, f, meals}. */
async function byDay(hc, from, to) {
  const rows = await all(
    hc,
    `SELECT day, SUM(kcal) AS kcal, SUM(protein_g) AS p, SUM(carbs_g) AS c,
            SUM(fat_g) AS f, COUNT(*) AS meals
       FROM meal_log
      WHERE day BETWEEN ? AND ?
      GROUP BY day
      ORDER BY day`,
    [from, to],
  );
  const map = new Map();
  for (const r of rows) {
    map.set(r.day, {
      kcal: Math.round(Number(r.kcal) || 0),
      p: Math.round(Number(r.p) || 0),
      c: Math.round(Number(r.c) || 0),
      f: Math.round(Number(r.f) || 0),
      meals: Number(r.meals) || 0,
    });
  }
  return map;
}

/** Map of ISO day -> the plan issued for that day. `SELECT *` because the
 *  scripts add columns over time (e.g. `out_lag_minutes`), and a hardcoded
 *  column list would break the dashboard every time they do. */
async function targetsByDay(hc, from, to) {
  const rows = await all(hc, 'SELECT * FROM daily_targets WHERE day BETWEEN ? AND ? ORDER BY day', [from, to]);
  const map = new Map();
  for (const r of rows) {
    map.set(r.day, {
      kcal: r.target_kcal === null ? null : Math.round(r.target_kcal),
      p: r.protein_g === null ? null : Math.round(r.protein_g),
      c: r.carbs_g === null ? null : Math.round(r.carbs_g),
      f: r.fat_g === null ? null : Math.round(r.fat_g),
      addback: r.addback_kcal === null ? null : Math.round(r.addback_kcal),
      planned_deficit: r.deficit_kcal === null ? null : Math.round(r.deficit_kcal),
      reco: r.reco_label || null,
      tdee: r.tdee === null ? null : Math.round(r.tdee),
      weight_avg7: r.weight_avg7 === null ? null : Number(r.weight_avg7),
      /* What the EOD recorded about the closed day. */
      eod_in: r.actual_in_kcal === null || r.actual_in_kcal === undefined ? null : Math.round(r.actual_in_kcal),
      eod_out: r.actual_out_kcal === null || r.actual_out_kcal === undefined ? null : Math.round(r.actual_out_kcal),
      finalized: Number(r.finalized || 0) === 1,
    });
  }
  return map;
}

/** Recovery label per day, from the evening check that writes tomorrow's plan. */
async function recsByDay(hc, from, to) {
  const rows = await all(
    hc,
    'SELECT for_day, label, source_day, detail FROM recovery_recs WHERE for_day BETWEEN ? AND ? ORDER BY for_day',
    [from, to],
  );
  const map = new Map();
  for (const r of rows) {
    map.set(r.for_day, { label: r.label, source_day: r.source_day, detail: r.detail });
  }
  return map;
}

/** First and last day the food log covers. */
async function coverage(hc) {
  const rows = await all(
    hc,
    `SELECT MIN(day) AS first, MAX(day) AS last, COUNT(*) AS rows FROM meal_log`,
  );
  const r = rows[0] || {};
  return { first: r.first || null, last: r.last || null, rows: Number(r.rows) || 0 };
}

module.exports = { byDay, targetsByDay, recsByDay, coverage };
