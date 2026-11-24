'use strict';
/**
 * Fixture-based tests for the two places where the dashboard decides what a
 * number means: which rows count as "the watch", and what a value reads back as.
 *
 * These run against a throwaway database built in the test, so they hold without
 * the live archive. The live cross-check is `npm run test:parity`, which compares
 * whole days against the reference Python scripts.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');

const { open, text, scalar, sqlite3 } = require('../src/db');
const time = require('../src/time');
const energy = require('../src/providers/energy');
const recovery = require('../src/providers/recovery');
const series = require('../src/series');
const { provisionalFor } = series;
const api = require('../src/api');
const cache = require('../src/cache');
const { serveStatic } = require('../app');

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
        `INSERT INTO health_metrics (uuid, data_type, start_date, end_date, value, source, metadata)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [
          r.uuid,
          r.type,
          r.start,
          r.end,
          r.value === undefined ? '' : String(r.value),
          r.source === undefined ? null : r.source,
          r.metadata === undefined
            ? null
            : (typeof r.metadata === 'string' ? r.metadata : JSON.stringify(r.metadata)),
        ],
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

/* ── Issue #1 & Issue #14: Client XSS prevention & URL query encoding ── */

function createMockDom() {
  const elementsById = new Map();
  class MockNode {
    constructor(tag) {
      this.tagName = tag;
      this.children = [];
      this.className = '';
      this.hidden = false;
      this.value = '';
      this.type = '';
      this.checked = false;
      this.dataset = {};
      this.listeners = {};
      this.style = {
        props: {},
        setProperty(k, v) { this.props[k] = v; },
      };
      this._text = '';
      this.parentElement = null;
      this.width = 600;
      this.height = 240;
      this.clientWidth = 600;
      this.clientHeight = 240;
    }
    get innerHTML() { return ''; }
    set innerHTML(_v) {
      throw new Error(`innerHTML must never be assigned (on <${this.tagName}>)`);
    }
    get textContent() {
      if (this.children.length) return this.children.map((c) => c.textContent).join('');
      return this._text;
    }
    set textContent(v) {
      this.children = [];
      this._text = String(v);
    }
    appendChild(child) {
      child.parentElement = this;
      this.children.push(child);
      return child;
    }
    insertBefore(child, ref) {
      child.parentElement = this;
      const idx = this.children.indexOf(ref);
      if (idx === -1) this.children.push(child);
      else this.children.splice(idx, 0, child);
      return child;
    }
    addEventListener(ev, fn) {
      if (!this.listeners[ev]) this.listeners[ev] = [];
      this.listeners[ev].push(fn);
    }
    dispatchEvent() {}
    querySelector(sel) {
      if (sel.startsWith('.')) {
        const cls = sel.slice(1);
        return this.children.find((c) => c.className.split(/\s+/).includes(cls)) || null;
      }
      return null;
    }
    querySelectorAll() { return []; }
    closest() { return this.parentElement; }
    getBoundingClientRect() { return { left: 0, top: 0, width: 600, height: 240 }; }
    getContext() {
      return {
        setTransform() {}, clearRect() {}, fillRect() {}, fillText() {},
        beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}, arc() {}, fill() {},
        save() {}, restore() {}, setLineDash() {}, measureText: () => ({ width: 20 }),
      };
    }
  }

  const makeEl = (tag, id) => {
    const el = new MockNode(tag);
    if (id) elementsById.set(id, el);
    return el;
  };

  for (const id of ['banner', 'summary', 'metric-picker', 'status', 'from', 'to', 'grain', 'tz-label', 'apply']) {
    makeEl('div', id);
  }
  for (const id of ['c-energy', 'c-balance', 'c-macros', 'c-weight', 'c-recovery', 'c-training', 'c-custom']) {
    const card = makeEl('div');
    card.className = 'card';
    const canvas = makeEl('canvas', id);
    card.appendChild(canvas);
  }

  const document = {
    getElementById: (id) => elementsById.get(id) || null,
    createElement: (tag) => new MockNode(tag),
    createTextNode: (t) => {
      const n = new MockNode('#text');
      n._text = String(t);
      return n;
    },
    querySelectorAll: () => [],
    addEventListener: () => {},
  };
  return { document, elementsById, MockNode };
}

test('Issue #1: dashboard/public/*.js never use innerHTML and render XSS payloads as text', async () => {
  const appSrc = fs.readFileSync(path.join(__dirname, '..', 'public', 'app.js'), 'utf8');
  const chartsSrc = fs.readFileSync(path.join(__dirname, '..', 'public', 'charts.js'), 'utf8');
  assert.strictEqual(appSrc.includes('.innerHTML'), false, 'public/app.js must not use innerHTML');
  assert.strictEqual(chartsSrc.includes('.innerHTML'), false, 'public/charts.js must not use innerHTML');

  const { document, elementsById } = createMockDom();
  const payload = '<img src=x onerror=alert(1)>';
  const windowObj = {
    location: { pathname: '/', search: `?from=${encodeURIComponent(payload)}&to=2026-10-17` },
    history: { replaceState() {} },
    addEventListener() {},
    devicePixelRatio: 1,
    Charts: { render() {}, attach() {}, PASTEL: { dim: '#94a3b8' }, fmt: String },
  };
  const fetchMock = async (url) => {
    if (url === '/api/meta') {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          timezone: 'UTC',
          offset_hours: 0,
          today: '2026-10-17',
          metrics: [{ key: 'intake.kcal', label: '<b>Intake</b>', unit: 'kcal', group: 'food' }],
          coverage: { food: { first: '2026-10-01' }, energy: { first: '2026-01-01' } },
          quality: { lag_warning: false },
        }),
      };
    }
    return {
      ok: false,
      status: 400,
      json: async () => ({ ok: false, error: `bad 'from' date: ${payload} (want YYYY-MM-DD)` }),
    };
  };

  const sandbox = {
    window: windowObj,
    document,
    fetch: fetchMock,
    URLSearchParams,
    CustomEvent: class CustomEvent { constructor(t, d) { this.type = t; this.detail = d && d.detail; } },
    performance: { now: () => 0 },
    Charts: windowObj.Charts,
  };
  vm.runInNewContext(appSrc, sandbox);
  await new Promise((r) => setTimeout(r, 20));

  const banner = elementsById.get('banner');
  assert.strictEqual(banner.hidden, false);
  assert.strictEqual(banner.children.length, 1);
  assert.strictEqual(banner.children[0].tagName, 'div');
  assert.strictEqual(banner.children[0].children.length, 0, 'no HTML child elements parsed from error');
  assert.ok(banner.children[0].textContent.includes(payload), 'payload preserved safely as textContent');

  /* Also verify charts.js tooltip never calls innerHTML on mousemove. */
  vm.runInNewContext(chartsSrc, sandbox);
  const canvas = elementsById.get('c-energy');
  sandbox.window.Charts.attach(canvas);
  canvas._chart = {
    labels: ['<script>alert(1)</script>'],
    pad: { l: 0 },
    sw: 100,
    spec: { provisional: [false] },
    series: [{ name: '<img src=x>', unit: '<b>kcal</b>', values: [123] }],
  };
  canvas.listeners.mousemove[0]({ clientX: 10, clientY: 10 });
  const tip = canvas.parentElement.querySelector('.tip');
  assert.ok(tip, 'tooltip node created');
  assert.strictEqual(tip.hidden, false);
  assert.ok(tip.textContent.includes('<script>alert(1)</script>'));
  assert.ok(tip.textContent.includes('<img src=x>'));
});

test('Issue #14: public/app.js encodes all query parameters via URLSearchParams', async () => {
  const appSrc = fs.readFileSync(path.join(__dirname, '..', 'public', 'app.js'), 'utf8');
  const { document } = createMockDom();
  const fetched = [];
  const rawFrom = '2026-10-01&injected=evil';
  const rawTo = '2026-10-02#frag';
  const rawMetric = 'intake.kcal,bad&extra=1';
  const qs = new URLSearchParams({ from: rawFrom, to: rawTo, metric: rawMetric }).toString();

  const windowObj = {
    location: { pathname: '/', search: `?${qs}` },
    history: { replaceState() {} },
    addEventListener() {},
    devicePixelRatio: 1,
    Charts: { render() {}, attach() {}, PASTEL: { dim: '#94a3b8' }, fmt: String },
  };
  const fetchMock = async (url) => {
    fetched.push(url);
    if (url === '/api/meta') {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          timezone: 'UTC',
          offset_hours: 0,
          today: '2026-10-17',
          metrics: [],
          coverage: { food: { first: '2026-10-01' }, energy: { first: '2026-01-01' } },
          quality: { lag_warning: false },
        }),
      };
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({ ok: true, series: [], days_complete: 0, days_provisional: 0 }),
    };
  };

  vm.runInNewContext(appSrc, {
    window: windowObj,
    document,
    fetch: fetchMock,
    URLSearchParams,
    performance: { now: () => 0 },
    Charts: windowObj.Charts,
  });
  await new Promise((r) => setTimeout(r, 20));

  const summaryUrl = fetched.find((u) => u.startsWith('/api/summary?'));
  assert.ok(summaryUrl, 'fetched /api/summary');
  const parsedSummary = new URL(summaryUrl, 'http://localhost');
  assert.strictEqual(parsedSummary.searchParams.get('from'), rawFrom);
  assert.strictEqual(parsedSummary.searchParams.get('to'), rawTo);
  assert.strictEqual(parsedSummary.searchParams.has('injected'), false);
  assert.strictEqual(parsedSummary.hash, '');

  const customUrl = fetched.find((u) => u.includes('bad%26extra'));
  assert.ok(customUrl, 'custom /api/series URL encoded & inside metric');
  const parsedCustom = new URL(customUrl, 'http://localhost');
  assert.strictEqual(parsedCustom.searchParams.get('metric'), rawMetric);
  assert.strictEqual(parsedCustom.searchParams.has('extra'), false);
  assert.strictEqual(parsedCustom.searchParams.get('from'), rawFrom);
  assert.strictEqual(parsedCustom.searchParams.get('to'), rawTo);
});

/* ── Issue #2: Static file serving hardening ─────────────────────────── */

function callServeStatic(method, pathname, publicDir) {
  return new Promise((resolve) => {
    const res = {
      statusCode: null,
      headers: {},
      body: null,
      writeHead(code, headers = {}) {
        this.statusCode = code;
        this.headers = headers;
      },
      end(chunk) {
        this.body = chunk === undefined ? '' : (Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk));
        resolve(this);
      },
    };
    serveStatic({ method }, res, pathname, publicDir);
  });
}

test('Issue #2: serveStatic enforces method, safe decodeURIComponent, and strict containment', async () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'dd-static-'));
  const pub = path.join(base, 'public');
  const sibling = path.join(base, 'public-secret');
  fs.mkdirSync(pub);
  fs.mkdirSync(sibling);
  fs.writeFileSync(path.join(pub, 'ok.js'), 'console.log(1);\n');
  fs.writeFileSync(path.join(pub, 'space file.js'), '/* space */');
  fs.writeFileSync(path.join(sibling, 'leak.txt'), 'TOP_SECRET');

  const postRes = await callServeStatic('POST', '/ok.js', pub);
  assert.strictEqual(postRes.statusCode, 405);
  assert.strictEqual(postRes.headers.Allow, 'GET, HEAD');

  const delRes = await callServeStatic('DELETE', '/ok.js', pub);
  assert.strictEqual(delRes.statusCode, 405);

  const badPct = await callServeStatic('GET', '/%ZZ', pub);
  assert.strictEqual(badPct.statusCode, 400);

  const nullByte = await callServeStatic('GET', '/ok.js%00.png', pub);
  assert.strictEqual(nullByte.statusCode, 400);

  const siblingRaw = await callServeStatic('GET', '/../public-secret/leak.txt', pub);
  assert.strictEqual(siblingRaw.statusCode, 403);
  assert.strictEqual(siblingRaw.body.includes('TOP_SECRET'), false);

  const siblingEncoded = await callServeStatic('GET', '/%2e%2e/public-secret/leak.txt', pub);
  assert.strictEqual(siblingEncoded.statusCode, 403);
  assert.strictEqual(siblingEncoded.body.includes('TOP_SECRET'), false);

  const rootDir = await callServeStatic('GET', '/', pub);
  assert.strictEqual(rootDir.statusCode, 404);

  const getOk = await callServeStatic('GET', '/ok.js', pub);
  assert.strictEqual(getOk.statusCode, 200);
  assert.strictEqual(getOk.body, 'console.log(1);\n');

  const encodedSpace = await callServeStatic('GET', '/space%20file.js', pub);
  assert.strictEqual(encodedSpace.statusCode, 200);
  assert.strictEqual(encodedSpace.body, '/* space */');

  const headOk = await callServeStatic('HEAD', '/ok.js', pub);
  assert.strictEqual(headOk.statusCode, 200);
  assert.strictEqual(headOk.body, '');
  assert.strictEqual(headOk.headers['Content-Length'], Buffer.byteLength('console.log(1);\n'));
});

/* ── Issue #3 & Issue #11: Error caching, ?fresh=1, midnight/TZ cache keys ── */

function mockApiRes() {
  return {
    statusCode: null,
    headers: {},
    body: null,
    writeHead(code, headers = {}) {
      this.statusCode = code;
      this.headers = headers;
    },
    end(textBody) {
      this.body = JSON.parse(textBody);
    },
  };
}

test('Issue #3: api.handle never caches 4xx or 5xx error responses', async () => {
  cache.clear();
  const route = api.ROUTES.find((r) => r.path === '/api/meta');
  const origHandler = route.handler;
  let calls = 0;

  try {
    /* 1. 400 response must not be cached. */
    route.handler = async () => {
      calls += 1;
      return { status: 400, body: { error: 'bad input' } };
    };
    const u400 = new URL('http://localhost/api/meta?bad=1');
    const r1 = mockApiRes();
    await api.handle({}, r1, u400);
    assert.strictEqual(r1.statusCode, 400);
    assert.strictEqual(cache.size(), 0);

    const r2 = mockApiRes();
    await api.handle({}, r2, u400);
    assert.strictEqual(r2.statusCode, 400);
    assert.strictEqual(r2.headers['X-Dashboard-Cache'], 'miss');
    assert.strictEqual(calls, 2);

    /* 2. 500 thrown error must not be cached; subsequent 200 succeeds and caches. */
    let shouldThrow = true;
    route.handler = async () => {
      calls += 1;
      if (shouldThrow) throw new Error('transient db lock');
      return { status: 200, body: { recovered: true } };
    };
    const u500 = new URL('http://localhost/api/meta?check=recovery');
    const rErr = mockApiRes();
    await api.handle({}, rErr, u500);
    assert.strictEqual(rErr.statusCode, 500);
    assert.strictEqual(cache.size(), 0);

    shouldThrow = false;
    const rOk = mockApiRes();
    await api.handle({}, rOk, u500);
    assert.strictEqual(rOk.statusCode, 200);
    assert.strictEqual(rOk.body.recovered, true);
    assert.strictEqual(rOk.headers['X-Dashboard-Cache'], 'miss');
    assert.strictEqual(cache.size(), 1);

    const rHit = mockApiRes();
    await api.handle({}, rHit, u500);
    assert.strictEqual(rHit.statusCode, 200);
    assert.strictEqual(rHit.headers['X-Dashboard-Cache'], 'hit');
    assert.strictEqual(calls, 4);
  } finally {
    route.handler = origHandler;
    cache.clear();
  }
});

test('Issue #11: cachedBuildRange bypasses on bypassCache and separates midnight/timezone keys', async () => {
  series.windowCache.clear();
  let builds = 0;
  const buildFn = async (from, to, opts) => {
    builds += 1;
    return { build: builds, from, to, today: opts.ctx.today, tz: opts.ctx.tz };
  };

  const day1Ctx = { tz: 'UTC', off: 0, today: '2026-10-17' };
  const day1Now = new Date('2026-10-17T23:55:00Z');

  const first = await series.cachedBuildRange('2026-10-01', '2026-10-17', { ctx: day1Ctx, now: day1Now, buildFn });
  const second = await series.cachedBuildRange('2026-10-01', '2026-10-17', { ctx: day1Ctx, now: day1Now, buildFn });
  assert.strictEqual(first.build, 1);
  assert.strictEqual(second.build, 1, 'normal second call hits windowCache');
  assert.strictEqual(builds, 1);

  /* bypassCache (?fresh=1) rebuilds and refreshes windowCache. */
  const refreshed = await series.cachedBuildRange('2026-10-01', '2026-10-17', {
    ctx: day1Ctx, now: day1Now, bypassCache: true, buildFn,
  });
  assert.strictEqual(refreshed.build, 2);
  const afterRefresh = await series.cachedBuildRange('2026-10-01', '2026-10-17', { ctx: day1Ctx, now: day1Now, buildFn });
  assert.strictEqual(afterRefresh.build, 2, 'subsequent call sees refreshed window');
  assert.strictEqual(builds, 2);

  /* Midnight rollover changes today -> cache miss. */
  const day2Ctx = { tz: 'UTC', off: 0, today: '2026-10-18' };
  const day2Now = new Date('2026-10-18T00:05:00Z');
  const afterMidnight = await series.cachedBuildRange('2026-10-01', '2026-10-17', {
    ctx: day2Ctx, now: day2Now, buildFn,
  });
  assert.strictEqual(afterMidnight.build, 3);

  /* Timezone change on the same local day -> cache miss. */
  const nyCtx = { tz: 'America/New_York', off: -4, today: '2026-10-18' };
  const afterTzFlip = await series.cachedBuildRange('2026-10-01', '2026-10-17', {
    ctx: nyCtx, now: day2Now, buildFn,
  });
  assert.strictEqual(afterTzFlip.build, 4);

  /* api.handle forwards ?fresh=1 as bypassCache to route handlers. */
  cache.clear();
  const rangeRoute = api.ROUTES.find((r) => r.path === '/api/range');
  const origRange = rangeRoute.handler;
  const seenOpts = [];
  try {
    rangeRoute.handler = async (_q, opts) => {
      seenOpts.push(opts);
      return { status: 200, body: { freshSeen: Boolean(opts && opts.fresh), n: seenOpts.length } };
    };
    const rA = mockApiRes();
    await api.handle({}, rA, new URL('http://localhost/api/range?from=2026-10-01&to=2026-10-10'));
    assert.strictEqual(rA.body.n, 1);

    const rB = mockApiRes();
    await api.handle({}, rB, new URL('http://localhost/api/range?from=2026-10-01&to=2026-10-10&fresh=1'));
    assert.strictEqual(rB.body.freshSeen, true);
    assert.strictEqual(rB.body.n, 2);
    assert.strictEqual(rB.headers['X-Dashboard-Cache'], 'miss');

    /* Non-fresh request after ?fresh=1 sees the refreshed cached value. */
    const rC = mockApiRes();
    await api.handle({}, rC, new URL('http://localhost/api/range?from=2026-10-01&to=2026-10-10'));
    assert.strictEqual(rC.headers['X-Dashboard-Cache'], 'hit');
    assert.strictEqual(rC.body.n, 2);
  } finally {
    rangeRoute.handler = origRange;
    cache.clear();
    series.windowCache.clear();
  }
});

/* ── Issue #4, #6, #9: Workouts without kcal, non-UTC offsets, deduplication ── */

test('Issue #4: recovery.daily keeps workouts missing totalEnergyBurned', async () => {
  const { db } = await fixture([
    {
      uuid: 'w1',
      type: recovery.WORKOUT,
      start: '2026-10-17T08:00:00Z',
      end: '2026-10-17T08:45:00Z',
      value: '50',
      source: WATCH,
      metadata: { duration: '2700', workoutActivityType: '50' }, // no totalEnergyBurned
    },
    {
      uuid: 'w2',
      type: recovery.WORKOUT,
      start: '2026-10-17T17:00:00Z',
      end: '2026-10-17T17:30:00Z',
      value: '37',
      source: WATCH,
      metadata: { duration: '1800', workoutActivityType: '37', totalEnergyBurned: '320 kcal' },
    },
    {
      uuid: 'w3',
      type: recovery.WORKOUT,
      start: '2026-10-18T09:00:00Z',
      end: '2026-10-18T09:40:00Z',
      value: '57',
      source: WATCH,
      metadata: { duration: '2400', workoutActivityType: '57', totalEnergyBurned: null },
    },
  ]);

  const out = await recovery.daily(db, 0, '2026-10-17', '2026-10-18');
  assert.deepStrictEqual(out.workouts.get('2026-10-17'), {
    sessions: 2,
    minutes: 75,
    kcal: 320,
    types: ['traditional strength training', 'running'],
    type: 'traditional strength training, running',
  });
  assert.deepStrictEqual(out.workouts.get('2026-10-18'), {
    sessions: 1,
    minutes: 40,
    kcal: 0,
    types: ['yoga'],
    type: 'yoga',
  });
});

test('Issue #6: parseTimestampMs, energy.lastSample, and recovery.daily handle non-UTC offsets', async () => {
  const expected = Date.parse('2026-10-17T10:00:00Z');
  assert.strictEqual(time.parseTimestampMs('2026-10-17T10:00:00Z'), expected);
  assert.strictEqual(time.parseTimestampMs('2026-10-17 10:00:00'), expected);
  assert.strictEqual(time.parseTimestampMs('2026-10-17T12:00:00+02:00'), expected);
  assert.strictEqual(time.parseTimestampMs('2026-10-17T05:00:00-05:00'), expected);
  assert.strictEqual(time.parseTimestampMs('2026-10-17T15:30:00+0530'), expected);
  assert.strictEqual(time.parseTimestampMs('2026-10-17 12:00:00 +0200'), expected);

  const { db } = await fixture([
    {
      uuid: 'e1',
      type: ACTIVE,
      start: '2026-10-17T11:55:00+02:00',
      end: '2026-10-17T12:00:00+02:00',
      value: 15,
      source: WATCH,
    },
    {
      uuid: 's1',
      type: recovery.SLEEP,
      start: '2026-10-17T01:00:00+02:00',
      end: '2026-10-17T08:00:00+02:00',
      value: 3,
      source: WATCH,
    },
    {
      uuid: 'w1',
      type: recovery.WORKOUT,
      start: '2026-10-17T09:00:00-05:00',
      end: '2026-10-17T09:45:00-05:00',
      value: '37',
      source: WATCH,
      metadata: { workoutActivityType: '37', totalEnergyBurned: '410' },
    },
  ]);

  const last = await energy.lastSample(db, new Date('2026-10-17T11:00:00Z'));
  assert.strictEqual(last.lag_minutes, 60, '12:00+02:00 is 10:00Z, 60m before 11:00Z');

  const rec = await recovery.daily(db, 2, '2026-10-17', '2026-10-17');
  assert.strictEqual(rec.sleep.get('2026-10-17'), 7);
  assert.strictEqual(rec.workouts.get('2026-10-17').sessions, 1);
  assert.strictEqual(rec.workouts.get('2026-10-17').minutes, 45);
  assert.strictEqual(rec.workouts.get('2026-10-17').kcal, 410);
});

test('Issue #9: recovery.daily deduplicates overlapping multi-writer workouts and prefers Watch', async () => {
  const { db } = await fixture([
    {
      uuid: 'w-watch',
      type: recovery.WORKOUT,
      start: '2026-10-17T08:00:00Z',
      end: '2026-10-17T08:45:00Z',
      value: '37',
      source: WATCH,
      metadata: { duration: '2700', workoutActivityType: '37', totalEnergyBurned: '400' },
    },
    {
      uuid: 'w-strava',
      type: recovery.WORKOUT,
      start: '2026-10-17T08:00:10Z',
      end: '2026-10-17T08:45:20Z',
      value: '37',
      source: 'Strava',
      metadata: { duration: '2710', workoutActivityType: '37', totalEnergyBurned: '460' },
    },
    {
      uuid: 'w-oura',
      type: recovery.WORKOUT,
      start: '2026-10-17T08:01:00Z',
      end: '2026-10-17T08:44:00Z',
      value: '37',
      source: 'Oura',
      metadata: { duration: '2580', workoutActivityType: '37', totalEnergyBurned: '380' },
    },
    {
      uuid: 'w-peloton',
      type: recovery.WORKOUT,
      start: '2026-10-17T17:00:00Z',
      end: '2026-10-17T17:30:00Z',
      value: '13',
      source: 'Peloton',
      metadata: { duration: '1800', workoutActivityType: '13', totalEnergyBurned: '250' },
    },
  ]);

  const out = await recovery.daily(db, 0, '2026-10-17', '2026-10-17');
  assert.deepStrictEqual(out.workouts.get('2026-10-17'), {
    sessions: 2,
    minutes: 75,
    kcal: 650,
    types: ['running', 'cycling'],
    type: 'running, cycling',
  });
});

/* ── Issue #10: tzOffsetMinutes midnight & hour "24" handling ────────── */

test('Issue #10: tzOffsetMinutes handles local midnight accurately and partsToUtcMs advances hour 24', () => {
  assert.strictEqual(time.tzOffsetMinutes('UTC', new Date('2026-07-01T00:00:00Z')), 0);
  assert.strictEqual(time.tzOffsetMinutes('America/New_York', new Date('2026-07-01T04:00:00Z')), -240);
  assert.strictEqual(time.tzOffsetMinutes('America/New_York', new Date('2026-01-15T05:00:00Z')), -300);
  assert.strictEqual(time.tzOffsetMinutes('Asia/Tokyo', new Date('2026-07-01T15:00:00Z')), 540);
  assert.strictEqual(time.tzOffsetMinutes('Asia/Kolkata', new Date('2026-07-01T18:30:00Z')), 330);
  assert.strictEqual(time.tzOffsetMinutes('America/New_York', new Date('2026-07-01T04:00:00.789Z')), -240);
  assert.strictEqual(time.tzOffsetMinutes('Invalid/Timezone', new Date('2026-07-01T00:00:00Z')), null);

  /* If an older ICU emits hour "24" for end-of-day midnight, advance to next day 00:00:00. */
  const advanced = time.partsToUtcMs({
    year: '2026', month: '06', day: '30', hour: '24', minute: '00', second: '00',
  });
  assert.strictEqual(advanced, Date.UTC(2026, 6, 1, 0, 0, 0));
});
