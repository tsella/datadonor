'use strict';
/**
 * Central config. Every path, filter literal and threshold lives here exactly
 * once — providers must never re-declare them, or two queries drift apart and
 * the dashboard starts disagreeing with the daily reports.
 */
const path = require('path');

const ROOT = path.resolve(__dirname, '..');

module.exports = {
  root: ROOT,
  /* Bind address is configurable because of how this is usually exposed. A
     reverse proxy that owns the public port cannot share it with a listener on
     0.0.0.0, which covers every local address. Bind the loopback address and let
     the proxy forward to it. */
  bindHost: process.env.DASH_HOST || '0.0.0.0',
  port: Number(process.env.DASH_PORT || 8765),

  /* Data sources. Both are opened READ-ONLY; the dashboard never writes.
     The archive is the ingest server's database next door. The second database is
     an optional food log: set HEALTH_DB to point at one, otherwise the intake
     channels stay empty. No home-directory layout is assumed. */
  ddDb: process.env.DD_DB || path.join(ROOT, '..', 'server', 'data', 'datadonor.sqlite'),
  healthDb: process.env.HEALTH_DB || path.join(ROOT, 'data', 'health-log.sqlite'),

  /* Timezone used for day buckets when the food log is absent. Override per
     deployment; UTC keeps a fresh clone running without guessing a location. */
  defaultTz: process.env.DASH_TZ || 'UTC',

  /**
   * Energy rows are matched with `source LIKE '%Apple%'`, NOT with the literal
   * name. The watch writes its source as "<owner>’s Apple\u00a0Watch" — U+2019 for
   * the apostrophe and U+00A0 (no-break space) between "Apple" and "Watch", so
   * `source = 'Apple Watch'` and `LIKE '%Apple Watch%'` both match nothing at
   * all. This pattern deliberately never spans that gap. Other sources (Oura,
   * StepsApp, the phone) double-count and must not enter.
   */
  energySourceLike: '%Apple%',

  /* A day's energy is provisional until the phone uploads it. */
  syncLagWarnMinutes: 60,

  /* A workout shorter than this is an artifact, not a session. */
  minSessionMinutes: 10,

  /* Range guards, so a bad URL cannot ask the server for 5 years of raw rows. */
  limits: {
    maxRangeDays: 1200,
    defaultRangeDays: 30,
    maxSummaryDays: 1200,
  },

  cacheTtlMs: 60000,
};
