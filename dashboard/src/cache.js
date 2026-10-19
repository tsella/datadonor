'use strict';
/**
 * Tiny TTL memo for API responses.
 *
 * Range queries hit millions of rows, and a dashboard page issues several at
 * once; this keeps a burst of requests off the database without ever serving
 * something stale enough to matter. `?fresh=1` bypasses it, which is what to
 * use while debugging a number.
 */
const cfg = require('./config');

const store = new Map();

function keyOf(req) {
  return req.url;
}

function get(req) {
  const hit = store.get(keyOf(req));
  if (!hit) return null;
  if (Date.now() - hit.at > cfg.cacheTtlMs) {
    store.delete(keyOf(req));
    return null;
  }
  return hit.value;
}

function set(req, value) {
  store.set(keyOf(req), { at: Date.now(), value });
  if (store.size > 200) {
    /* Cheap bound: drop the oldest entries rather than grow without limit. */
    const keys = [...store.keys()].slice(0, store.size - 200);
    for (const k of keys) store.delete(k);
  }
  return value;
}

function clear() {
  store.clear();
}

module.exports = { get, set, clear, size: () => store.size };
