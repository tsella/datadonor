'use strict';
/**
 * The metric registry — the contract that makes this expandable.
 *
 * A metric is a name, a unit, an aggregation rule and a function from a day
 * frame to a value. Everything else (the API, the series endpoint, the chart
 * specs, the filters in the UI) reads this table, so exposing a new number
 * means adding one line here and nothing else. No route, no chart and no
 * filter ever enumerates metrics by hand.
 *
 * Two fields are load-bearing:
 *
 *  - `kind`: `measured` means a device or a log produced it; `derived` means
 *    arithmetic between two channels, and it is null whenever either input is
 *    missing. A derived value is never back-filled from a default — that is
 *    exactly how the previous dashboard ended up drawing charts of nothing.
 *  - `agg`: how the metric combines over a longer grain. Summing is right for
 *    flows (calories in, calories out, minutes) and nonsense for levels
 *    (weight, resting HR, HRV), so the rule travels with the metric instead of
 *    being guessed by whoever writes the chart.
 */
const energy = require('./energy');
const intake = require('./intake');
const body = require('./body');
const recovery = require('./recovery');

function num(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

const METRICS = {
  /* Food in — flows */
  'intake.kcal': { label: 'Intake', unit: 'kcal', group: 'food', kind: 'measured', agg: 'sum', get: (f) => num(f.intake && f.intake.kcal) },
  'intake.p': { label: 'Protein', unit: 'g', group: 'food', kind: 'measured', agg: 'sum', get: (f) => num(f.intake && f.intake.p) },
  'intake.c': { label: 'Carbs', unit: 'g', group: 'food', kind: 'measured', agg: 'sum', get: (f) => num(f.intake && f.intake.c) },
  'intake.f': { label: 'Fat', unit: 'g', group: 'food', kind: 'measured', agg: 'sum', get: (f) => num(f.intake && f.intake.f) },
  'intake.meals': { label: 'Meals logged', unit: 'n', group: 'food', kind: 'measured', agg: 'sum', get: (f) => num(f.intake && f.intake.meals) },

  /* The plan — targets are flows too, so a week compares against a week */
  'target.kcal': { label: 'Target', unit: 'kcal', group: 'target', kind: 'measured', agg: 'sum', get: (f) => num(f.target && f.target.kcal) },
  'target.p': { label: 'Protein target', unit: 'g', group: 'target', kind: 'measured', agg: 'sum', get: (f) => num(f.target && f.target.p) },
  'target.c': { label: 'Carb target', unit: 'g', group: 'target', kind: 'measured', agg: 'sum', get: (f) => num(f.target && f.target.c) },
  'target.f': { label: 'Fat ceiling', unit: 'g', group: 'target', kind: 'measured', agg: 'sum', get: (f) => num(f.target && f.target.f) },
  'target.planned_deficit': { label: 'Planned deficit', unit: 'kcal', group: 'target', kind: 'measured', agg: 'mean', get: (f) => num(f.target && f.target.planned_deficit) },

  /* Energy out — flows */
  'out.basal': { label: 'Basal', unit: 'kcal', group: 'energy', kind: 'measured', agg: 'sum', get: (f) => num(f.out && f.out.basal) },
  'out.active': { label: 'Active', unit: 'kcal', group: 'energy', kind: 'measured', agg: 'sum', get: (f) => num(f.out && f.out.active) },
  'out.total': { label: 'Total out', unit: 'kcal', group: 'energy', kind: 'measured', agg: 'sum', get: (f) => num(f.out && f.out.total) },

  /* Derived — null unless both inputs exist */
  deficit: {
    label: 'Deficit',
    unit: 'kcal',
    group: 'derived',
    kind: 'derived',
    agg: 'sum',
    /* POSITIVE means a deficit (out above in), which is the convention every
       other part of this system uses — the EOD report, the the daily report replies and
       the planned 500. Signed the other way it drew as a negative bar sitting
       under a positive plan line. */
    get: (f) => (num(f.intake && f.intake.kcal) !== null && num(f.out && f.out.total) !== null
      ? Math.round(f.out.total - f.intake.kcal)
      : null),
  },
  balance_vs_target: {
    label: 'In vs target',
    unit: 'kcal',
    group: 'derived',
    kind: 'derived',
    agg: 'sum',
    get: (f) => (num(f.intake && f.intake.kcal) !== null && num(f.target && f.target.kcal) !== null
      ? Math.round(f.intake.kcal - f.target.kcal)
      : null),
  },
  protein_gap: {
    label: 'Protein short of floor',
    unit: 'g',
    group: 'derived',
    kind: 'derived',
    agg: 'mean',
    get: (f) => (num(f.intake && f.intake.p) !== null && num(f.target && f.target.p) !== null
      ? Math.round(f.target.p - f.intake.p)
      : null),
  },
  fat_over: {
    label: 'Fat over ceiling',
    unit: 'g',
    group: 'derived',
    kind: 'derived',
    agg: 'mean',
    get: (f) => (num(f.intake && f.intake.f) !== null && num(f.target && f.target.f) !== null
      ? Math.round(f.intake.f - f.target.f)
      : null),
  },

  /* Body — levels */
  'weight.kg': { label: 'Weight', unit: 'kg', group: 'body', kind: 'measured', agg: 'mean', get: (f) => num(f.weight && f.weight.kg) },
  'weight.avg7': { label: 'Weight (7-day mean)', unit: 'kg', group: 'body', kind: 'derived', agg: 'mean', get: (f) => num(f.weight && f.weight.avg7) },

  /* Recovery — levels */
  rhr: { label: 'Resting HR', unit: 'bpm', group: 'recovery', kind: 'measured', agg: 'mean', get: (f) => num(f.rhr) },
  hrv: { label: 'HRV', unit: 'ms', group: 'recovery', kind: 'measured', agg: 'mean', get: (f) => num(f.hrv) },
  'sleep.h': { label: 'Sleep', unit: 'h', group: 'recovery', kind: 'measured', agg: 'mean', get: (f) => num(f.sleep_h) },
  'temp.c': { label: 'Wrist temp', unit: '°C', group: 'recovery', kind: 'measured', agg: 'mean', get: (f) => num(f.temp_c) },

  /* Training — flows */
  'workout.kcal': { label: 'Session kcal', unit: 'kcal', group: 'training', kind: 'measured', agg: 'sum', get: (f) => num(f.workout && f.workout.kcal) },
  'workout.minutes': { label: 'Session minutes', unit: 'min', group: 'training', kind: 'measured', agg: 'sum', get: (f) => num(f.workout && f.workout.minutes) },
  'workout.sessions': { label: 'Sessions', unit: 'n', group: 'training', kind: 'measured', agg: 'sum', get: (f) => num(f.workout && f.workout.sessions) },
};

/** [{key, label, unit, group, kind, agg}] — for /api/meta and the UI filters. */
function list() {
  return Object.entries(METRICS).map(([key, m]) => ({
    key,
    label: m.label,
    unit: m.unit,
    group: m.group,
    kind: m.kind,
    agg: m.agg,
  }));
}

function get(key) {
  return METRICS[key] || null;
}

module.exports = { METRICS, list, get, num, energy, intake, body, recovery };
