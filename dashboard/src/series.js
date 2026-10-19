'use strict';
/**
 * The one place a date range becomes data.
 *
 * `buildRange(from, to)` returns a day frame per local day, and `series()`
 * projects any registered metric out of those frames. Every endpoint goes
 * through here, so the dashboard has exactly one definition of "a day" and one
 * definition of "the deficit" — the failure mode being designed out is the old
 * one, where the page and the the daily report report disagreed about the same date.
 *
 * Day bucketing uses the travel-aware offset (see time.js), and each frame
 * carries its own `quality` block, so a provisional day is identifiable by
 * consumers instead of being mistaken for a complete one.
 */
const cfg = require('./config');
const time = require('./time');
const registry = require('./providers');
const { all, sources } = require('./db');

const TRAVEL_SQL =
  `SELECT destination, direction, timezone_home, timezone_dest, arrival_local, landing_date
     FROM travel`;

/** Active timezone + whole-hour offset right now. */
async function context(now = new Date()) {
  const { hc } = sources();
  let rows = [];
  try {
    rows = await all(hc, TRAVEL_SQL);
  } catch (err) {
    rows = [];
  }
  const tz = time.activeTimezone(rows, now);
  const off = time.offsetHoursFor(tz, now);
  return { tz, off, today: time.todayLocal(off, now) };
}

/** Which channels have no data at all for a day — drives honest gaps in the UI. */
function missingChannels(frame) {
  const missing = [];
  if (!frame.intake) missing.push('intake');
  if (!frame.out) missing.push('out');
  if (!frame.target) missing.push('target');
  if (!frame.weight) missing.push('weight');
  if (frame.rhr === null) missing.push('rhr');
  if (frame.hrv === null) missing.push('hrv');
  if (frame.sleep_h === null) missing.push('sleep');
  return missing;
}

/**
 * A day is provisional while its energy may still change.
 *
 * Today always is. An earlier day is too when the newest energy sample is older
 * than the warn window: the watch has not uploaded since, so the last day with
 * data can still grow. The old rule read `isToday || (day === today && lagWarn)`,
 * whose second clause can never add anything the first did not already cover, so
 * a sync that stalled for a day passed as final.
 */
function provisionalFor(day, { today, lastEnergyDay, lagMinutes, warnMinutes }) {
  if (day === today) return true;
  if (day !== lastEnergyDay) return false;
  return lagMinutes !== null && lagMinutes > warnMinutes;
}

/** One day frame per local day in [from, to]. */
async function buildRange(from, to, opts = {}) {
  const now = opts.now || new Date();
  const { dd, hc } = sources();
  const { tz, off, today } = await context(now);

  const [energyMap, intakeMap, targetMap, recsMap, weightMap, rec, last] = await Promise.all([
    registry.energy.byDay(dd, off, from, to),
    registry.intake.byDay(hc, from, to),
    registry.intake.targetsByDay(hc, from, to),
    registry.intake.recsByDay(hc, from, to),
    registry.body.byDay(dd, off, from, to),
    registry.recovery.daily(dd, off, from, to),
    registry.energy.lastSample(dd, now),
  ]);

  const lagWarn = last.lag_minutes !== null && last.lag_minutes > cfg.syncLagWarnMinutes;
  /* Newest day the watch has energy for. Only that day can still be growing. */
  const lastEnergyDay = energyMap.size ? [...energyMap.keys()].sort().pop() : null;
  const days = time.daysBetween(from, to).map((day) => {
    const frame = {
      date: day,
      intake: intakeMap.get(day) || null,
      target: targetMap.get(day) || null,
      out: energyMap.get(day) || null,
      weight: weightMap.get(day) || null,
      rhr: rec.rhr.has(day) ? rec.rhr.get(day) : null,
      hrv: rec.hrv.has(day) ? rec.hrv.get(day) : null,
      sleep_h: rec.sleep.has(day) ? rec.sleep.get(day) : null,
      temp_c: rec.temp.has(day) ? rec.temp.get(day) : null,
      /* A day with energy but no session is a rest day — a real zero, which
         the scripts also report. A day with no energy at all is UNKNOWN and
         stays null, so it draws as a gap rather than as "trained nothing". */
      workout: rec.workouts.get(day)
        || (energyMap.has(day) ? { sessions: 0, minutes: 0, kcal: 0 } : null),
      reco: recsMap.get(day) || null,
    };
    /* Today's energy is always still arriving; a stalled sync makes the last
       day with data provisional too, so a late upload never reads as final. */
    const isToday = day === today;
    const provisional = provisionalFor(day, {
      today,
      lastEnergyDay,
      lagMinutes: last.lag_minutes,
      warnMinutes: cfg.syncLagWarnMinutes,
    });
    frame.quality = {
      provisional,
      is_today: isToday,
      finalized: Boolean(frame.target && frame.target.finalized),
      lag_minutes: provisional ? last.lag_minutes : null,
      missing: missingChannels(frame),
    };
    return frame;
  });

  return {
    from,
    to,
    timezone: tz,
    offset_hours: off,
    today,
    generated_at: now.toISOString(),
    days,
    quality: {
      last_energy_sample_at: last.at,
      lag_minutes: last.lag_minutes,
      lag_warning: lagWarn,
      provisional_days: days.filter((d) => d.quality.provisional).map((d) => d.date),
    },
  };
}

/** Combine a metric's daily points into a coarser grain. */
function aggregate(points, agg) {
  const vals = points.map((p) => p.value).filter((v) => v !== null && v !== undefined);
  if (!vals.length) return null;
  if (agg === 'sum') return Math.round(vals.reduce((a, b) => a + b, 0) * 100) / 100;
  if (agg === 'last') return vals[vals.length - 1];
  return Math.round((vals.reduce((a, b) => a + b, 0) / vals.length) * 100) / 100;
}

/** Group day frames into buckets of the requested grain. */
function bucket(days, grain) {
  if (grain !== 'week') return days.map((d) => ({ key: d.date, days: [d] }));
  const buckets = new Map();
  for (const d of days) {
    const key = time.isoWeek(d.date);
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push(d);
  }
  return [...buckets.entries()].map(([key, group]) => ({ key, days: group }));
}

/**
 * Project metrics out of a range.
 * `metrics` is a list of registry keys; unknown keys are reported in `errors`
 * rather than silently dropped, so a typo in a URL is visible.
 */
function series(range, metricKeys, grain = 'day') {
  const errors = [];
  const metas = [];
  for (const key of metricKeys) {
    const m = registry.get(key);
    if (!m) errors.push(`unknown metric: ${key}`);
    else metas.push({ key, ...m });
  }
  const groups = bucket(range.days, grain);
  const out = metas.map((m) => {
    const points = groups.map((g) => {
      const raw = g.days.map((f) => ({
        date: f.date,
        value: m.get(f),
        provisional: f.quality.provisional,
      }));
      return {
        key: g.key,
        from: g.days[0].date,
        to: g.days[g.days.length - 1].date,
        value: grain === 'day' ? (raw[0] ? raw[0].value : null) : aggregate(raw, m.agg),
        provisional: raw.some((p) => p.provisional),
        points: grain === 'day' ? undefined : raw.map((p) => ({ date: p.date, value: p.value })),
      };
    });
    return {
      key: m.key,
      label: m.label,
      unit: m.unit,
      group: m.group,
      kind: m.kind,
      agg: m.agg,
      points,
    };
  });
  return { grain, series: out, errors };
}

/** Aggregates over a window, excluding provisional days from every mean. */
function summary(range) {
  const complete = range.days.filter((d) => !d.quality.provisional);
  const val = (f, key) => {
    const m = registry.get(key);
    return m ? m.get(f) : null;
  };
  const collect = (key) => complete.map((f) => val(f, key)).filter((v) => v !== null);

  const mean = (xs) => (xs.length ? Math.round((xs.reduce((a, b) => a + b, 0) / xs.length) * 100) / 100 : null);
  const sum = (xs) => (xs.length ? Math.round(xs.reduce((a, b) => a + b, 0)) : null);

  const deficits = collect('deficit');
  const balances = collect('balance_vs_target');
  const proteinGaps = collect('protein_gap');
  const fatOvers = collect('fat_over');
  const weights = collect('weight.avg7').length ? collect('weight.avg7') : collect('weight.kg');
  const intakeDays = collect('intake.kcal').length;

  /* A day "hit the floor" only when both the intake and the target exist. */
  const floorHit = complete.filter((f) => {
    const gap = val(f, 'protein_gap');
    return gap !== null && gap <= 0;
  }).length;
  const fatOverDays = complete.filter((f) => {
    const over = val(f, 'fat_over');
    return over !== null && over > 0;
  }).length;

  const withDeficit = complete
    .map((f) => ({ date: f.date, deficit: val(f, 'deficit') }))
    .filter((d) => d.deficit !== null)
    .sort((a, b) => b.deficit - a.deficit);

  return {
    from: range.from,
    to: range.to,
    days_total: range.days.length,
    days_complete: complete.length,
    days_provisional: range.days.length - complete.length,
    days_with_intake: intakeDays,
    mean_intake_kcal: mean(collect('intake.kcal')),
    mean_out_kcal: mean(collect('out.total')),
    mean_target_kcal: mean(collect('target.kcal')),
    mean_deficit_kcal: mean(deficits),
    total_deficit_kcal: sum(deficits),
    mean_planned_deficit_kcal: mean(collect('target.planned_deficit')),
    mean_balance_vs_target: mean(balances),
    mean_protein_g: mean(collect('intake.p')),
    mean_protein_target_g: mean(collect('target.p')),
    mean_protein_gap_g: mean(proteinGaps),
    protein_floor_days: floorHit,
    mean_fat_g: mean(collect('intake.f')),
    mean_fat_ceiling_g: mean(collect('target.f')),
    fat_over_days: fatOverDays,
    mean_weight_kg: mean(weights),
    weight_first_kg: weights.length ? weights[0] : null,
    weight_last_kg: weights.length ? weights[weights.length - 1] : null,
    best_deficit_day: withDeficit.length ? withDeficit[0] : null,
    worst_deficit_day: withDeficit.length ? withDeficit[withDeficit.length - 1] : null,
    total_workout_kcal: sum(collect('workout.kcal')),
    total_workout_minutes: sum(collect('workout.minutes')),
    sessions: sum(collect('workout.sessions')),
    mean_sleep_h: mean(collect('sleep.h')),
    mean_rhr: mean(collect('rhr')),
    mean_hrv: mean(collect('hrv')),
  };
}

/**
 * Window cache, keyed by the window rather than by the URL.
 *
 * A dashboard load fires seven range queries — six panels plus the summary —
 * and every one of them was rebuilding the same day frames: seven identical
 * passes over ~2M rows, ~6.8 s of wall clock. Keying on `from|to` collapses
 * them into ONE build, and storing the in-flight promise (not just the result)
 * means concurrent callers join the work already running instead of starting
 * their own.
 */
const WINDOW_TTL_MS = 30000;
const WINDOW_CACHE_MAX = 24;
const windowCache = new Map();

function cachedBuildRange(from, to, opts = {}) {
  const key = `${from}|${to}`;
  const hit = windowCache.get(key);
  if (hit && Date.now() - hit.at < WINDOW_TTL_MS) return hit.promise;
  const promise = buildRange(from, to, opts).catch((err) => {
    windowCache.delete(key);
    throw err;
  });
  windowCache.set(key, { at: Date.now(), promise });
  if (windowCache.size > WINDOW_CACHE_MAX) {
    for (const k of [...windowCache.keys()].slice(0, windowCache.size - WINDOW_CACHE_MAX)) {
      windowCache.delete(k);
    }
  }
  return promise;
}

module.exports = { buildRange, cachedBuildRange, series, summary, context, bucket, aggregate, provisionalFor, windowCache };
