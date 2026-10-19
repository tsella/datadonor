'use strict';
/**
 * Fixture-based tests for the two places where the dashboard decides what a
 * number means: which rows count as "the watch", and what a value reads back as.
 *
 * These run against a throwaway database built in the test, so they hold without
 * the live archive. The live cross-check is `npm run test:parity`, which compares
 * whole days against the Python meal scripts.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { open, text, scalar, sqlite3 } = require('../src/db');
const energy = require('../src/providers/energy');
const { provisionalFor } = require('../src/series');

const BASAL = 'HKQuantityTypeIdentifierBasalEnergyBurned';
const ACTIVE = 'HKQuantityTypeIdentifierActiveEnergyBurned';

/* The watch writes U+2019 for the apostrophe and U+00A0 between "Apple" and
   "Watch", which is why the provider filters with LIKE '%Apple%'. */
const WATCH = 'Tom\u2019s Apple\u00a0Watch';

const SCHEMA = `
  CREATE TABLE health_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT UNIQUE,
    device_id TEXT,
    data_type TEXT NOT NULL,
    start_date DATETIME NOT NULL,
    end_date DATETIME NOT NULL,
    value TEXT NOT NULL,
    unit TEXT,
    source TEXT,
    metadata JSON,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );`;

async function fixture(rows) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dd-dash-'));
  const file = path.join(dir, 'fixture.sqlite');
  const writer = new sqlite3.Database(file);
  await new Promise((resolve, reject) => writer.exec(SCHEMA, (e) => (e ? reject(e) : resolve())));
  const insert = (r) =>
    new Promise((resolve, reject) => {
      writer.run(
        `INSERT INTO health_metrics (uuid, data_type, start_date, end_date, value, source)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [r.uuid, r.type, r.start, r.end, r.value, r.source],
        (e) => (e ? reject(e) : resolve()),
      );
    });
  for (const r of rows) await insert(r);
  await new Promise((resolve) => writer.close(resolve));
  return { dir, db: open(file) };
}

test('text() returns values that scalar() cannot: dates and versions', async () => {
  const { db } = await fixture([
    { uuid: 'a', type: ACTIVE, start: '2026-10-17T10:00:00Z', end: '2026-10-17T10:05:00Z', value: 12, source: WATCH },
  ]);
  const sql = 'SELECT MAX(end_date) FROM health_metrics';
  assert.strictEqual(await text(db, sql), '2026-10-17T10:05:00Z');
  /* Number("2026-10-17T10:05:00Z") is NaN, so scalar drops it. That is the trap
     that made the sync-lag report read null for every request. */
  assert.strictEqual(await scalar(db, sql), null);
});

test('lastSample reports the newest watch sample and its age', async () => {
  const newer = '2026-10-17T12:00:00Z';
  const { db } = await fixture([
    { uuid: 'a', type: ACTIVE, start: '2026-10-17T10:00:00Z', end: '2026-10-17T10:05:00Z', value: 12, source: WATCH },
    { uuid: 'b', type: ACTIVE, start: '2026-10-17T11:55:00Z', end: newer, value: 9, source: WATCH },
    /* A newer row from another source must not move the timestamp. */
    { uuid: 'c', type: ACTIVE, start: '2026-10-18T09:00:00Z', end: '2026-10-18T09:05:00Z', value: 40, source: 'Oura' },
  ]);
  const out = await energy.lastSample(db, new Date('2026-10-17T13:00:00Z'));
  assert.strictEqual(out.at, newer);
  assert.strictEqual(out.lag_minutes, 60);
});

test('lastSample returns nulls when the archive holds no watch rows', async () => {
  const { db } = await fixture([
    { uuid: 'a', type: ACTIVE, start: '2026-10-17T10:00:00Z', end: '2026-10-17T10:05:00Z', value: 40, source: 'Oura' },
  ]);
  const out = await energy.lastSample(db);
  assert.deepStrictEqual(out, { at: null, lag_minutes: null });
});

test('byDay sums the watch only, never a second source', async () => {
  const { db } = await fixture([
    { uuid: 'a', type: BASAL, start: '2026-10-17T00:00:00Z', end: '2026-10-17T00:05:00Z', value: 100, source: WATCH },
    { uuid: 'b', type: ACTIVE, start: '2026-10-17T10:00:00Z', end: '2026-10-17T10:05:00Z', value: 50, source: WATCH },
    { uuid: 'c', type: ACTIVE, start: '2026-10-17T10:00:00Z', end: '2026-10-17T10:05:00Z', value: 500, source: 'Oura' },
  ]);
  const map = await energy.byDay(db, 0, '2026-10-17', '2026-10-17');
  assert.deepStrictEqual(map.get('2026-10-17'), { basal: 100, active: 50, total: 150, samples: 2 });
});

test('a day with no rows stays absent, not zero', async () => {
  const { db } = await fixture([
    { uuid: 'a', type: ACTIVE, start: '2026-10-17T10:00:00Z', end: '2026-10-17T10:05:00Z', value: 50, source: WATCH },
  ]);
  const map = await energy.byDay(db, 0, '2026-10-16', '2026-10-17');
  assert.strictEqual(map.has('2026-10-16'), false);
});

test('provisionalFor flags today, a stalled last day, and nothing older', () => {
  const base = { today: '2026-10-18', lastEnergyDay: '2026-10-17', lagMinutes: 180, warnMinutes: 60 };
  assert.strictEqual(provisionalFor('2026-10-18', base), true, 'today is always provisional');
  assert.strictEqual(provisionalFor('2026-10-17', base), true, 'stale sync leaves the last day open');
  assert.strictEqual(provisionalFor('2026-10-16', { ...base, lastEnergyDay: '2026-10-18' }), false);
  assert.strictEqual(provisionalFor('2026-10-17', { ...base, lagMinutes: 5 }), false, 'fresh sync closes it');
  assert.strictEqual(provisionalFor('2026-10-17', { ...base, lagMinutes: null }), false, 'unknown lag is not a warning');
});
