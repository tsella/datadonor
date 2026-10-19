'use strict';
/**
 * JSON API. Every handler returns data for a window; none of them renders
 * anything. The browser is responsible for presentation, which is why the same
 * endpoints serve the dashboard, a curl check and any future consumer.
 *
 * Contract notes:
 *  - Bad input is a 400 with a message, never a silent default. A typo in a
 *    date or a metric name should be visible, not averaged away.
 *  - `meta` reports per-source coverage so the UI can clamp the range picker to
 *    what actually exists (energy goes back to 2020, the food log to 2026-09-19).
 *  - `quality` travels with every payload: which days are provisional, and how
 *    far behind the watch sync is.
 */
const cfg = require('./config');
const time = require('./time');
const registry = require('./providers');
const series = require('./series');
const cache = require('./cache');
const { all, sources, text: textValue } = require('./db');

function parseMetricList(raw) {
  return String(raw || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/** Resolve and validate a window from query params. */
function resolveRange(query, today) {
  const rawFrom = query.get('from');
  const rawTo = query.get('to');
  if (rawFrom && !time.ISO_DAY.test(rawFrom)) return { error: `bad 'from' date: ${rawFrom} (want YYYY-MM-DD)` };
  if (rawTo && !time.ISO_DAY.test(rawTo)) return { error: `bad 'to' date: ${rawTo} (want YYYY-MM-DD)` };
  let to = rawTo || today;
  let from = rawFrom || time.addDays(to, -(cfg.limits.defaultRangeDays - 1));
  if (from > to) [from, to] = [to, from];
  const n = time.rangeDays(from, to);
  if (n > cfg.limits.maxRangeDays) {
    return { error: `range too large: ${n} days (max ${cfg.limits.maxRangeDays})` };
  }
  return { from, to, days: n };
}

async function meta() {
  const { dd, hc } = sources();
  const now = new Date();
  const ctx = await series.context(now);
  const [energyCov, foodCov, weightSources, last, sqliteVersion] = await Promise.all([
    registry.energy.coverage(dd, ctx.off),
    registry.intake.coverage(hc),
    registry.body.sources(dd, ctx.off),
    registry.energy.lastSample(dd, now),
    textValue(dd, 'SELECT sqlite_version()'),
  ]);
  return {
    timezone: ctx.tz,
    offset_hours: ctx.off,
    today: ctx.today,
    generated_at: now.toISOString(),
    metrics: registry.list(),
    coverage: {
      energy: energyCov,
      food: foodCov,
      weight_sources: weightSources,
    },
    quality: {
      last_energy_sample_at: last.at,
      lag_minutes: last.lag_minutes,
      lag_warning: last.lag_minutes !== null && last.lag_minutes > cfg.syncLagWarnMinutes,
    },
    limits: cfg.limits,
    sqlite_version: sqliteVersion,
  };
}

async function rangeDay(query) {
  const ctx = await series.context();
  const r = resolveRange(query, ctx.today);
  if (r.error) return { status: 400, body: { error: r.error } };
  const range = await series.cachedBuildRange(r.from, r.to);
  return { status: 200, body: range };
}

async function rangeSeries(query) {
  const ctx = await series.context();
  const r = resolveRange(query, ctx.today);
  if (r.error) return { status: 400, body: { error: r.error } };
  const keys = parseMetricList(query.get('metric'));
  if (!keys.length) {
    return { status: 400, body: { error: "missing 'metric' (comma-separated registry keys; see /api/meta)" } };
  }
  const grain = query.get('grain') || 'day';
  if (!['day', 'week'].includes(grain)) {
    return { status: 400, body: { error: `bad grain: ${grain} (want day|week)` } };
  }
  if (keys.length > 12) {
    return { status: 400, body: { error: `too many metrics: ${keys.length} (max 12)` } };
  }
  const range = await series.cachedBuildRange(r.from, r.to);
  const out = series.series(range, keys, grain);
  if (out.errors.length) return { status: 400, body: { error: out.errors.join('; ') } };
  return {
    status: 200,
    body: {
      ...out,
      from: r.from,
      to: r.to,
      timezone: range.timezone,
      offset_hours: range.offset_hours,
      quality: range.quality,
    },
  };
}

async function rangeSummary(query) {
  const ctx = await series.context();
  const r = resolveRange(query, ctx.today);
  if (r.error) return { status: 400, body: { error: r.error } };
  const range = await series.cachedBuildRange(r.from, r.to);
  return {
    status: 200,
    body: {
      ...series.summary(range),
      timezone: range.timezone,
      quality: range.quality,
    },
  };
}

const ROUTES = [
  /* Every handler returns {status, body} — meta included. Returning the payload
     bare made `send()` read `.status` off the data and crash on the first call. */
  { path: '/api/meta', handler: async () => ({ status: 200, body: await meta() }) },
  { path: '/api/range', handler: (q) => rangeDay(q) },
  { path: '/api/series', handler: (q) => rangeSeries(q) },
  { path: '/api/summary', handler: (q) => rangeSummary(q) },
];

/**
 * Handle an /api/* request. Returns true when it owned the request.
 * `res` is a plain node response; callers pass the parsed URL.
 */
async function handle(req, res, url) {
  const route = ROUTES.find((r) => r.path === url.pathname);
  if (!route) return false;

  const fresh = url.searchParams.get('fresh') === '1';
  if (!fresh) {
    const hit = cache.get({ url: url.pathname + url.search });
    if (hit) {
      send(res, hit.status, hit.body, { cached: true });
      return true;
    }
  }

  let result;
  try {
    result = await route.handler(url.searchParams);
  } catch (err) {
    result = {
      status: 500,
      body: { error: 'query failed', detail: String(err && err.message ? err.message : err) },
    };
  }
  if (!fresh) cache.set({ url: url.pathname + url.search }, result);
  send(res, result.status, result.body, { cached: false });
  return true;
}

function send(res, status, body, extra = {}) {
  const payload = { ...body };
  if (status !== 200) payload.error = body.error || 'request failed';
  const text = JSON.stringify({ ok: status === 200, ...payload });
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Dashboard-Cache': extra.cached ? 'hit' : 'miss',
  });
  res.end(text);
}

module.exports = { handle, meta, resolveRange, ROUTES };
