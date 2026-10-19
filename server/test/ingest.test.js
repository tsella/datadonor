'use strict';
/**
 * Ingestion. The properties that matter are the ones the client relies on for
 * retries: a re-sent payload must not duplicate rows, must not inflate the
 * additive stats table, and a delete must not cross the device boundary.
 */
const test = require('node:test');
const assert = require('node:assert');
const sqlite3 = require('sqlite3');
const { startServer, samplePayload } = require('./helpers');

let srv;
test.before(async () => { srv = await startServer(); });
test.after(async () => { if (srv) await srv.stop(); });

function query(file, sql, params = []) {
  return new Promise((resolve, reject) => {
    const db = new sqlite3.Database(file, sqlite3.OPEN_READONLY);
    db.all(sql, params, (err, rows) => {
      db.close();
      if (err) reject(err);
      else resolve(rows);
    });
  });
}

const post = (payload, extraHeaders = {}) =>
  srv.call('/api/v1/health-sync/post', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
    body: JSON.stringify(payload),
  });

test('a new payload is inserted and counted', async () => {
  const res = await post(samplePayload('device-a'));
  assert.strictEqual(res.status, 201);
  assert.strictEqual(res.json.inserted, 5);
  assert.strictEqual(res.json.duplicates, 0);

  const rows = await query(srv.dbFile, 'SELECT COUNT(*) AS n FROM health_metrics');
  assert.strictEqual(rows[0].n, 5);
});

test('a re-sent payload changes nothing and inflates no stats', async () => {
  const again = await post(samplePayload('device-a'));
  assert.strictEqual(again.status, 201);
  assert.strictEqual(again.json.inserted, 0);
  assert.strictEqual(again.json.duplicates, 5);

  const rows = await query(srv.dbFile, 'SELECT COUNT(*) AS n FROM health_metrics');
  assert.strictEqual(rows[0].n, 5, 'no duplicate rows');

  const stats = await query(
    srv.dbFile,
    'SELECT data_type, record_count FROM daily_sync_stats WHERE device_id = ? ORDER BY data_type',
    ['device-a'],
  );
  assert.strictEqual(stats.length, 5);
  for (const row of stats) {
    assert.strictEqual(row.record_count, 1, `${row.data_type} counted once`);
  }
});

test('a duplicate inside one payload lands once', async () => {
  const payload = samplePayload('device-b');
  payload.data.push({ ...payload.data[0], value: '999' }); // same uuid, twice

  const res = await post(payload);
  assert.strictEqual(res.status, 201);
  assert.strictEqual(res.json.inserted, 5);
  assert.strictEqual(res.json.duplicates, 1);

  const rows = await query(
    srv.dbFile,
    'SELECT COUNT(*) AS n FROM health_metrics WHERE device_id = ?',
    ['device-b'],
  );
  assert.strictEqual(rows[0].n, 5);
});

test('a record without a uuid is refused', async () => {
  const payload = samplePayload('device-c');
  delete payload.data[2].uuid;
  const res = await post(payload);
  assert.strictEqual(res.status, 400);
  assert.match(res.json.error, /uuid \(index 2/);
});

test('a record with a malformed start_date is refused', async () => {
  const payload = samplePayload('device-c');
  payload.data[1].start_date = 'yesterday';
  const res = await post(payload);
  assert.strictEqual(res.status, 400);
  assert.match(res.json.error, /start_date/);
});

test('a payload that is not the expected shape is refused', async () => {
  const res = await post({ device_id: 'device-c', data: 'nope' });
  assert.strictEqual(res.status, 400);
  assert.match(res.json.error, /schema/);
});

test('a delete from another device leaves the row alone', async () => {
  const victim = samplePayload('device-d').data[0];
  const payload = samplePayload('device-d');
  payload.data = [victim];
  payload.device_id = 'device-d';
  assert.strictEqual((await post(payload)).json.inserted, 1);

  const hostile = {
    device_id: 'device-e',
    data: [],
    deleted_uuids: [victim.uuid],
    anchors: {},
  };
  const res = await post(hostile);
  assert.strictEqual(res.status, 201);
  assert.strictEqual(res.json.deleted, 0);

  const rows = await query(
    srv.dbFile,
    'SELECT COUNT(*) AS n FROM health_metrics WHERE uuid = ?',
    [victim.uuid],
  );
  assert.strictEqual(rows[0].n, 1, 'row still present');
});

test('the owning device can delete its own row', async () => {
  const res = await post({
    device_id: 'device-d',
    data: [],
    deleted_uuids: [samplePayload('device-d').data[0].uuid],
    anchors: {},
  });
  assert.strictEqual(res.json.deleted, 1);
});

test('anchors come back through the checkpoint endpoint', async () => {
  const res = await srv.call('/api/v1/health-sync/checkpoint', {
    headers: { 'X-Device-ID': 'device-a' },
  });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.json.checkpoints.HKQuantityTypeIdentifierStepCount, 'anchor-1');
  assert.strictEqual(res.json.total_records, 5);
});

test('stats buckets are explicit, not guessed from the type name', async () => {
  await post({
    device_id: 'device-stats',
    data: [
      { uuid: 's1', type: 'HKQuantityTypeIdentifierHeartRate', start_date: '2026-10-17T01:00:00Z', end_date: '2026-10-17T01:05:00Z', value: '60', source: 'w' },
      { uuid: 's2', type: 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN', start_date: '2026-10-17T02:00:00Z', end_date: '2026-10-17T02:05:00Z', value: '70', source: 'w' },
      { uuid: 's3', type: 'HKCategoryTypeIdentifierSleepAnalysis', start_date: '2026-10-17T03:00:00Z', end_date: '2026-10-17T03:05:00Z', value: '3', source: 'w' },
      { uuid: 's4', type: 'HKQuantityTypeIdentifierSomeFutureType', start_date: '2026-10-17T04:00:00Z', end_date: '2026-10-17T04:05:00Z', value: '1', source: 'w' },
    ],
    anchors: {},
  });

  const res = await srv.call('/api/v1/health-sync/stats?timeScale=days', {
    headers: { 'X-Device-ID': 'device-stats' },
  });
  assert.strictEqual(res.status, 200);
  const byDate = new Map(res.json.stats.map((s) => [s.type, s.count]));
  assert.strictEqual(byDate.get('Heart Rate'), 2, 'HR and SDNN share a bucket');
  assert.strictEqual(byDate.get('Sleep'), 1);
  assert.strictEqual(byDate.has('Other'), false, 'unknown type is dropped, not bucketed');
});
