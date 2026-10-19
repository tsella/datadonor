'use strict';
/**
 * Body handling. The client compresses the sync payload because it repeats the
 * same two long strings on every record, so the gzip path is the one that
 * actually carries the data. The decompressed-size guard is the one that stops
 * a small compressed body from expanding into gigabytes of heap.
 */
const test = require('node:test');
const assert = require('node:assert');
const zlib = require('zlib');
const { startServer, samplePayload } = require('./helpers');

let srv;
test.before(async () => { srv = await startServer(); });
test.after(async () => { if (srv) await srv.stop(); });

const send = (body, headers = {}) =>
  srv.call('/api/v1/health-sync/post', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body,
  });

test('a gzip payload is decompressed and ingested', async () => {
  const payload = samplePayload('device-gz');
  const res = await send(zlib.gzipSync(JSON.stringify(payload)), { 'Content-Encoding': 'gzip' });
  assert.strictEqual(res.status, 201);
  assert.strictEqual(res.json.inserted, 5);
});

test('an uncompressed payload still works', async () => {
  const payload = samplePayload('device-plain');
  payload.data = payload.data.slice(0, 2);
  const res = await send(JSON.stringify(payload));
  assert.strictEqual(res.status, 201);
  assert.strictEqual(res.json.inserted, 2);
});

test('a body that claims gzip but is not gzip is refused', async () => {
  const res = await send(Buffer.from('{"device_id":"x","data":[]}'), { 'Content-Encoding': 'gzip' });
  assert.strictEqual(res.status, 400);
});

test('malformed JSON is refused with 400, not 500', async () => {
  const res = await send('{"device_id": ');
  assert.strictEqual(res.status, 400);
});

test('an unsupported Content-Encoding is refused with 415', async () => {
  const res = await send('{"device_id":"x","data":[]}', { 'Content-Encoding': 'br' });
  assert.strictEqual(res.status, 415);
});

test('a small body that expands past the guard is refused', async () => {
  /* The limit is lowered to 4 KB through config.limits for this run only. A real
     200 MB bomb would have to allocate 200 MB to prove the same branch. */
  const small = await startServer({ limits: { maxDecompressedBytes: 4096 } });
  try {
    const payload = samplePayload('device-bomb');
    /* Pad with filler so the JSON expands well past 4 KB. */
    for (const rec of payload.data) rec.metadata = { filler: 'x'.repeat(20000) };
    const body = zlib.gzipSync(JSON.stringify(payload));
    assert.ok(body.length < 4096, `compressed body is ${body.length} bytes`);

    const res = await small.call('/api/v1/health-sync/post', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' },
      body,
    });
    assert.strictEqual(res.status, 400);

    const { open } = require('sqlite');
    const { Database } = require('sqlite3');
    const db = await open({ filename: small.dbFile, driver: Database, mode: Database.OPEN_READONLY });
    const row = await db.get('SELECT COUNT(*) AS n FROM health_metrics');
    await db.close();
    assert.strictEqual(row.n, 0, 'nothing was written before the refusal');
  } finally {
    await small.stop();
  }
});
