'use strict';
/**
 * The key gate. A public exposure of the archive is the worst outcome this
 * server has, so every path is checked: no header, wrong key of the wrong
 * length (timingSafeEqual throws on that), wrong key of the right length, and
 * the happy path.
 */
const test = require('node:test');
const assert = require('node:assert');
const { startServer } = require('./helpers');

let srv;
test.before(async () => { srv = await startServer(); });
test.after(async () => { if (srv) await srv.stop(); });

test('a request with no authorization header is rejected', async () => {
  const res = await srv.call('/api/v1/ping', { headers: { Authorization: '' } });
  assert.strictEqual(res.status, 401);
  assert.match(res.json.error, /Authorization/);
});

test('a key of the wrong length is rejected without throwing', async () => {
  const res = await srv.call('/api/v1/ping', { headers: { Authorization: 'Bearer short' } });
  assert.strictEqual(res.status, 403);
});

test('a key of the right length but wrong bytes is rejected', async () => {
  const wrong = 'x'.repeat(srv.apiKey.length);
  const res = await srv.call('/api/v1/ping', { headers: { Authorization: `Bearer ${wrong}` } });
  assert.strictEqual(res.status, 403);
});

test('the configured key reaches the route', async () => {
  const res = await srv.call('/api/v1/ping');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.json.status, 'ok');
});

test('checkpoint inquiry requires the device header', async () => {
  const res = await srv.call('/api/v1/health-sync/checkpoint');
  assert.strictEqual(res.status, 400);
  assert.match(res.json.error, /X-Device-ID/);
});
