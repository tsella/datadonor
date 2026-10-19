'use strict';
/**
 * EJS renders the SHELL only — layout, filter bar, empty containers. No data
 * is ever baked into the HTML: the browser fetches it from /api/*.
 *
 * That split is deliberate. The previous version rendered a context into the
 * template once at startup, which is how hardcoded fallbacks and invented
 * projection ramps ended up shipping as if they were measurements, and why no
 * URL could ask for a different date range.
 */
const fs = require('fs');
const path = require('path');
const ejs = require('ejs');
const cfg = require('./config');

const TEMPLATE = path.join(cfg.root, 'templates', 'layout.ejs');

function shell(context = {}) {
  const tpl = fs.readFileSync(TEMPLATE, 'utf8');
  return ejs.render(tpl, {
    title: context.title || 'DataDonor',
    generated: new Date().toISOString(),
    ...context,
  });
}

module.exports = { shell, TEMPLATE };
