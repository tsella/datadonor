'use strict';
/**
 * Travel-aware local time — a direct port of the rules in `meal_macros.py`, so
 * the dashboard buckets days EXACTLY like the reference scripts. If these two ever
 * disagree, every number here contradicts the daily reports.
 *
 * The rule that matters: the active timezone is the most recent leg already
 * LANDED, keyed on the arrival INSTANT rather than the landing date. A return
 * landing 20:20 local would otherwise flip Tom home at 00:00 on the landing
 * date — ~20 h early, while he is still sitting in the origin country.
 */
const cfg = require('./config');

/** Offset of `tzName` at a given UTC instant, in minutes (null if unknown). */
function tzOffsetMinutes(tzName, utcDate) {
  try {
    const dtf = new Intl.DateTimeFormat('en-US', {
      timeZone: tzName,
      hour12: false,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
    const p = {};
    for (const part of dtf.formatToParts(utcDate)) p[part.type] = part.value;
    const asUTC = Date.UTC(
      Number(p.year), Number(p.month) - 1, Number(p.day),
      Number(p.hour) % 24, Number(p.minute), Number(p.second),
    );
    return (asUTC - utcDate.getTime()) / 60000;
  } catch (err) {
    return null;
  }
}

/**
 * Interpret a naive wall clock (`2026-09-20T20:20:00`) as local time in a named
 * zone and return the UTC instant. Resolved iteratively because the offset
 * itself depends on the instant (DST).
 */
function zonedWallToUtc(naive, tzName) {
  const [datePart, timePart = '00:00:00'] = String(naive).replace(' ', 'T').split('T');
  const [Y, M, D] = datePart.split('-').map(Number);
  const [h, m, s = 0] = timePart.split(':').map(Number);
  let guess = Date.UTC(Y, M - 1, D, h, m, s);
  for (let i = 0; i < 3; i += 1) {
    const off = tzOffsetMinutes(tzName, new Date(guess));
    if (off === null) return null;
    const next = Date.UTC(Y, M - 1, D, h, m, s) - off * 60000;
    if (next === guess) break;
    guess = next;
  }
  return new Date(guess);
}

/** Arrival instant for a travel row, in UTC. */
function arrivalInstantUtc(row) {
  if (!row || !row.arrival_local) return null;
  const tz = row.direction === 'outbound' ? row.timezone_dest : row.timezone_home;
  return zonedWallToUtc(row.arrival_local, tz || row.timezone_home || cfg.defaultTz);
}

/** The timezone Tom is actually in, given the travel rows. */
function activeTimezone(rows, now = new Date()) {
  const landed = [];
  for (const row of rows || []) {
    const instant = arrivalInstantUtc(row);
    if (instant && instant.getTime() <= now.getTime()) {
      const tz = row.direction === 'outbound' ? row.timezone_dest : row.timezone_home;
      landed.push([instant.getTime(), tz || cfg.defaultTz]);
    }
  }
  if (!landed.length) return cfg.defaultTz;
  landed.sort((a, b) => a[0] - b[0]);
  return landed[landed.length - 1][1];
}

/** Whole-hour offset of a timezone at an instant. */
function offsetHoursFor(tzName, at = new Date()) {
  const mins = tzOffsetMinutes(tzName, at);
  if (mins === null) return -4;
  return Math.round(mins / 60);
}

/**
 * SQLite modifier that shifts a stored UTC timestamp into the local day, e.g.
 * `'+3 hours'`. Every day-bucketed query must use it: timestamps are stored as
 * `2026-10-11T14:08:24Z`, so a bare `date(start_date)` buckets by UTC and
 * silently moves a whole evening into the wrong day.
 */
function shiftMod(off) {
  const sign = off >= 0 ? '+' : '-';
  return `'${sign}${Math.abs(Math.round(off))} hours'`;
}

/** Tom's current calendar date at the given offset. */
function todayLocal(off, at = new Date()) {
  return new Date(at.getTime() + off * 3600000).toISOString().slice(0, 10);
}

function addDays(iso, n) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function daysBetween(from, to) {
  const out = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}

function rangeDays(from, to) {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000) + 1;
}

/** ISO-8601 week key, e.g. `2026-W41`. */
function isoWeek(iso) {
  const d = new Date(`${iso}T00:00:00Z`);
  const day = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - day + 3);
  const firstThu = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  const firstDay = (firstThu.getUTCDay() + 6) % 7;
  firstThu.setUTCDate(firstThu.getUTCDate() - firstDay + 3);
  const week = 1 + Math.round((d - firstThu) / (7 * 86400000));
  return `${d.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

module.exports = {
  tzOffsetMinutes,
  zonedWallToUtc,
  arrivalInstantUtc,
  activeTimezone,
  offsetHoursFor,
  shiftMod,
  todayLocal,
  addDays,
  daysBetween,
  rangeDays,
  isoWeek,
  ISO_DAY,
};
