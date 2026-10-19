'use strict';
/**
 * Central config. Every path, filter literal and threshold lives here exactly
 * once — providers must never re-declare them, or two queries drift apart and
 * the dashboard starts disagreeing with the the daily report reports.
 */
const path = require('path');

const ROOT = path.resolve(__dirname, '..');

module.exports = {
  root: ROOT,
  /* Bind address is configurable because of HOW this is exposed: `tailscale
     serve` needs to own the public/tailnet port, and the dashboard currently
     binds 0.0.0.0, which covers every local address — a second listener on
     either 127.0.0.1:8765 or 100.x:8765 then fails with EADDRINUSE (verified).
     Cutover: DASH_HOST=127.0.0.1 DASH_PORT=8790 + `tailscale serve --https=8765`
     pointed at the loopback port, so the URL keeps its port and the app stops
     listening on every interface it can see. */
  bindHost: process.env.DASH_HOST || '0.0.0.0',
  port: Number(process.env.DASH_PORT || 8765),

  /* Data sources. Both are opened READ-ONLY; the dashboard never writes. */
  ddDb: process.env.DD_DB || '/home/user/datadonor/server/data/datadonor.sqlite',
  healthDb: process.env.HEALTH_DB || '/home/user/.config/cache/health_log.sqlite',

  /* Home timezone, used only when the travel table is empty or unreadable. */
  defaultTz: 'America/New_York',

  /**
   * Energy rows are matched with `source LIKE '%Apple%'`, NOT with the literal
   * name. The watch writes itself as `Tom\u2019s Apple\u00a0Watch` — U+2019 for
   * the apostrophe and U+00A0 (no-break space) between "Apple" and "Watch", so
   * `source = 'Tom''s Apple Watch'` and `LIKE '%Apple Watch%'` both match
   * nothing at all. This pattern deliberately never spans that gap.
   * Other sources (Oura, StepsApp, the iPhone) double-count and must not enter.
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
