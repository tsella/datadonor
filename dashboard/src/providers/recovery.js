'use strict';
/**
 * Recovery channels: resting HR, HRV, sleep, workouts, wrist temperature.
 *
 * Two of these need care:
 *
 *  - **Sleep is double-counted across five writers** (Oura, the watch, the
 *    iPhone, Clock, Connect). Summing every row roughly doubles the night, so
 *    this reads the watch only and then UNION-MERGES overlapping intervals —
 *    overlapping stages are one stretch of sleep, not two.
 *  - **Workouts carry their real numbers in the `metadata` JSON**, not in
 *    `value`; sessions missing `totalEnergyBurned` still count toward session
 *    count and duration (with 0 kcal), and overlapping multi-writer sessions
 *    (e.g. Watch + Strava/Oura) are deduplicated with preference for the
 *    configured primary watch source.
 */
const cfg = require('../config');
const { all } = require('../db');
const time = require('../time');

const RHR = 'HKQuantityTypeIdentifierRestingHeartRate';
const HRV = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN';
const TEMP = 'HKQuantityTypeIdentifierAppleSleepingWristTemperature';
const SLEEP = 'HKCategoryTypeIdentifierSleepAnalysis';
const WORKOUT = 'HKWorkoutTypeIdentifier';

/* HKCategoryValueSleepAnalysis: 0 inBed, 1 asleepUnspecified, 2 awake,
   3 asleepCore, 4 asleepDeep, 5 asleepREM. Only genuine sleep counts. */
const ASLEEP_STAGES = [1, 3, 4, 5];

/**
 * HealthKit workout activity codes, as they appear in `metadata`. The number is
 * the only reliable field — the watch writes no type NAME — so this table is
 * what stops a lifting session being labelled a walk.
 *
 * Only codes actually present in Tom's data are listed, and each was verified
 * against Apple's documented enum rather than guessed. That matters: a wrong
 * table is worse than no table. An earlier draft of this file guessed
 * `21 = functional training`, `24 = flexibility`, `43 = walking (indoor)`,
 * `64 = core`, `70 = yoga` — the real values are Golf, Hiking, Squash, Jump Rope
 * and Wheelchair Walk Pace. Anything not below renders as `type N`, which is
 * ugly and true, rather than pretty and wrong.
 */
const WORKOUT_TYPES = {
  11: 'cross training',
  13: 'cycling',
  20: 'functional strength training',
  33: 'prep and recovery',
  35: 'rowing',
  37: 'running',
  50: 'traditional strength training',
  52: 'walking',
  57: 'yoga',
  73: 'mixed cardio',
};

function workoutTypeName(code) {
  if (code === undefined || code === null || code === '') return null;
  const n = Number(code);
  return WORKOUT_TYPES[n] || `type ${n}`;
}

function meanPerDay(rows, off) {
  const acc = new Map();
  for (const r of rows) {
    const d = r.d;
    const cur = acc.get(d) || { sum: 0, n: 0 };
    cur.sum += Number(r.v);
    cur.n += 1;
    acc.set(d, cur);
  }
  const out = new Map();
  for (const [d, v] of acc) out.set(d, Number((v.sum / v.n).toFixed(1)));
  return out;
}

/** Convert a SQL LIKE pattern (e.g. '%Apple%') into a case-insensitive RegExp. */
function likeToRegex(pattern) {
  const escaped = String(pattern || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^${escaped.replace(/%/g, '.*').replace(/_/g, '.')}$`, 'i');
}

/** True when two workout intervals overlap by at least 50% of the shorter one. */
function workoutsOverlap(a, b) {
  const overlap = Math.min(a.endMs, b.endMs) - Math.max(a.startMs, b.startMs);
  if (overlap <= 0) return false;
  const shorter = Math.min(a.endMs - a.startMs, b.endMs - b.startMs);
  if (shorter <= 0) return true;
  return overlap / shorter >= 0.5;
}

/**
 * Deduplicate overlapping multi-writer workouts (e.g. Watch + Strava/Oura),
 * preferring the configured primary watch source (`cfg.energySourceLike`),
 * then sessions with energy data, then longer sessions.
 */
function dedupeWorkouts(candidates) {
  const ranked = [...candidates].sort((a, b) => {
    if (a.preferred !== b.preferred) return a.preferred ? -1 : 1;
    if (a.hasKcal !== b.hasKcal) return a.hasKcal ? -1 : 1;
    if (a.kcal !== b.kcal) return b.kcal - a.kcal;
    if (a.minutes !== b.minutes) return b.minutes - a.minutes;
    return a.startMs - b.startMs;
  });
  const accepted = [];
  for (const c of ranked) {
    if (accepted.some((a) => workoutsOverlap(a, c))) continue;
    accepted.push(c);
  }
  return accepted.sort((a, b) => a.startMs - b.startMs);
}

/** Merge overlapping [start,end] intervals and return total minutes. */
function mergedMinutes(intervals) {
  if (!intervals.length) return 0;
  intervals.sort((a, b) => a[0] - b[0]);
  let total = 0;
  let [curStart, curEnd] = intervals[0];
  for (let i = 1; i < intervals.length; i += 1) {
    const [s, e] = intervals[i];
    if (s <= curEnd) {
      curEnd = Math.max(curEnd, e);
    } else {
      total += curEnd - curStart;
      [curStart, curEnd] = [s, e];
    }
  }
  total += curEnd - curStart;
  return total / 60000;
}

async function daily(dd, off, from, to) {
  const mod = time.shiftMod(off);
  const [rhrRows, hrvRows, tempRows] = await Promise.all([
    all(dd, `SELECT date(start_date, ${mod}) AS d, CAST(value AS REAL) AS v FROM health_metrics
              WHERE data_type = '${RHR}' AND source LIKE ? AND date(start_date, ${mod}) BETWEEN ? AND ?`,
      [cfg.energySourceLike, from, to]),
    all(dd, `SELECT date(start_date, ${mod}) AS d, CAST(value AS REAL) AS v FROM health_metrics
              WHERE data_type = '${HRV}' AND source LIKE ? AND date(start_date, ${mod}) BETWEEN ? AND ?`,
      [cfg.energySourceLike, from, to]),
    all(dd, `SELECT date(start_date, ${mod}) AS d, CAST(value AS REAL) AS v FROM health_metrics
              WHERE data_type = '${TEMP}' AND source LIKE ? AND date(start_date, ${mod}) BETWEEN ? AND ?`,
      [cfg.energySourceLike, from, to]),
  ]);

  /* Sleep: widen the UTC window by a day each side so a night that starts
     before midnight or ends after it is still seen in full. */
  const sleepRows = await all(
    dd,
    `SELECT start_date, end_date, CAST(value AS INTEGER) AS stage FROM health_metrics
      WHERE data_type = '${SLEEP}' AND source LIKE ?
        AND end_date >= ? AND start_date <= ?
      ORDER BY start_date`,
    [cfg.energySourceLike, `${time.addDays(from, -1)}T00:00:00Z`, `${time.addDays(to, 1)}T23:59:59Z`],
  );
  const buckets = new Map();
  for (const r of sleepRows) {
    if (!ASLEEP_STAGES.includes(Number(r.stage))) continue;
    const s = time.parseTimestampMs(r.start_date);
    const e = time.parseTimestampMs(r.end_date);
    if (!Number.isFinite(s) || !Number.isFinite(e) || e <= s) continue;
    /* Attribute the night to the day it ENDED — the morning he woke up on. */
    const wakeDay = time.todayLocal(off, new Date(e));
    if (!buckets.has(wakeDay)) buckets.set(wakeDay, []);
    buckets.get(wakeDay).push([s, e]);
  }
  const sleep = new Map();
  for (const [day, intervals] of buckets) {
    const mins = mergedMinutes(intervals);
    if (mins > 0) sleep.set(day, Number((mins / 60).toFixed(2)));
  }

  /* Workouts: parse all valid sessions, prefer configured watch source, and
     deduplicate overlapping multi-writer entries so sessions/minutes/kcal are
     never double-counted. Sessions without totalEnergyBurned are kept with 0 kcal. */
  const workoutRows = await all(
    dd,
    `SELECT start_date, end_date, source, metadata FROM health_metrics
      WHERE data_type = '${WORKOUT}' AND date(start_date, ${mod}) BETWEEN ? AND ?
      ORDER BY start_date`,
    [from, to],
  );
  const preferredRe = likeToRegex(cfg.energySourceLike);
  const candidates = [];
  for (const r of workoutRows) {
    let meta = {};
    try {
      meta = r.metadata ? JSON.parse(r.metadata) : {};
    } catch (err) {
      meta = {};
    }
    const startMs = time.parseTimestampMs(r.start_date);
    if (!Number.isFinite(startMs)) continue;
    const parsedEndMs = time.parseTimestampMs(r.end_date);
    const durRaw = meta.duration ?? meta.HKMetadataKeyDuration;
    let minutes = (durRaw !== undefined && durRaw !== null && durRaw !== '')
      ? Number(durRaw) / 60
      : NaN;
    if (!Number.isFinite(minutes) || minutes <= 0) {
      minutes = Number.isFinite(parsedEndMs) && parsedEndMs > startMs
        ? (parsedEndMs - startMs) / 60000
        : 0;
    }
    if (!(minutes >= cfg.minSessionMinutes)) continue;
    const endMs = Number.isFinite(parsedEndMs) && parsedEndMs > startMs
      ? parsedEndMs
      : startMs + minutes * 60000;

    const kcalRaw = meta.totalEnergyBurned ?? meta.HKMetadataKeyTotalEnergyBurned;
    const parsedKcal = (kcalRaw !== undefined && kcalRaw !== null && kcalRaw !== '')
      ? Number(String(kcalRaw).trim().split(/\s+/)[0])
      : NaN;
    const hasKcal = Number.isFinite(parsedKcal) && parsedKcal >= 0;
    const kcal = hasKcal ? parsedKcal : 0;

    candidates.push({
      startMs,
      endMs,
      minutes,
      kcal,
      hasKcal,
      name: workoutTypeName(meta.workoutActivityType ?? meta.activityType),
      source: r.source || '',
      preferred: preferredRe.test(r.source || ''),
    });
  }

  const workouts = new Map();
  for (const c of dedupeWorkouts(candidates)) {
    const day = time.todayLocal(off, new Date(c.startMs));
    const cur = workouts.get(day)
      || { sessions: 0, minutes: 0, kcal: 0, types: [] };
    cur.sessions += 1;
    cur.minutes += c.minutes;
    cur.kcal += c.kcal;
    if (c.name && !cur.types.includes(c.name)) cur.types.push(c.name);
    workouts.set(day, cur);
  }
  for (const v of workouts.values()) {
    v.minutes = Math.round(v.minutes);
    v.kcal = Math.round(v.kcal);
    v.type = v.types.length ? v.types.join(', ') : null;
  }

  return {
    rhr: meanPerDay(rhrRows, off),
    hrv: meanPerDay(hrvRows, off),
    temp: meanPerDay(tempRows, off),
    sleep,
    workouts,
  };
}

module.exports = {
  daily,
  mergedMinutes,
  likeToRegex,
  workoutsOverlap,
  dedupeWorkouts,
  ASLEEP_STAGES,
  RHR,
  HRV,
  TEMP,
  SLEEP,
  WORKOUT,
};
