'use strict';
/**
 * Read-only SQLite handles. The dashboard is a consumer: it never writes to
 * either database, so every handle is opened with OPEN_READONLY and a write
 * fails loudly instead of corrupting the ingest or the meal log.
 */
const sqlite3 = require('sqlite3').verbose();
const cfg = require('./config');

function open(file) {
  return new sqlite3.Database(file, sqlite3.OPEN_READONLY);
}

function all(db, sql, params = []) {
  return new Promise((resolve, reject) => {
    db.all(sql, params, (err, rows) => (err ? reject(err) : resolve(rows || [])));
  });
}

function get(db, sql, params = []) {
  return new Promise((resolve, reject) => {
    db.get(sql, params, (err, row) => (err ? reject(err) : resolve(row || null)));
  });
}

/** First column of the first row, coerced to a number (null when absent). */
async function scalar(db, sql, params = []) {
  const row = await get(db, sql, params);
  if (!row) return null;
  const v = Object.values(row)[0];
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/**
 * First column of the first row, as raw text. `scalar` runs `Number()` on the
 * value, so a date or a version string becomes NaN and silently reads back as
 * null. Anything that is not a number has to come through here.
 */
async function text(db, sql, params = []) {
  const row = await get(db, sql, params);
  if (!row) return null;
  const v = Object.values(row)[0];
  if (v === null || v === undefined || v === '') return null;
  return String(v);
}

/** Values as a `IN (?,?,?)` placeholder list. */
function placeholders(n) {
  return new Array(n).fill('?').join(',');
}

/* Process-lifetime handles: one read-only connection per database. */
const handles = {};
function sources() {
  if (!handles.dd) handles.dd = open(cfg.ddDb);
  if (!handles.hc) handles.hc = open(cfg.healthDb);
  return handles;
}

module.exports = { open, all, get, scalar, text, placeholders, sources, sqlite3 };
