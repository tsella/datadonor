'use strict';
/**
 * Entry point. Deliberately thin: it owns HTTP and nothing else.
 *
 *   /api/*    -> src/api.js    (JSON, no rendering)
 *   /         -> src/render.js (EJS shell, no data)
 *   /*.js/css -> public/       (client assets)
 *
 * There is no build step and no generated HTML file. The previous version
 * rendered a static page at startup and then served those same bytes forever,
 * which is why it could not answer a question about a date range.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const cfg = require('./src/config');
const api = require('./src/api');
const render = require('./src/render');

const PUBLIC_DIR = path.resolve(__dirname, 'public');
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function serveStatic(req, res, pathname, publicDir = PUBLIC_DIR) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, {
      'Content-Type': 'text/plain; charset=utf-8',
      Allow: 'GET, HEAD',
    });
    res.end('Method Not Allowed');
    return;
  }

  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch (err) {
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Bad request');
    return;
  }
  if (decoded.includes('\0')) {
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Bad request');
    return;
  }

  /* Strict containment check: prevent `..` and sibling-prefix escapes (e.g. public-secret). */
  const root = path.resolve(publicDir);
  const rel = decoded.replace(/^[/\\]+/, '');
  const resolved = path.resolve(root, rel);
  if (resolved !== root && !resolved.startsWith(root + path.sep)) {
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Forbidden');
    return;
  }
  if (resolved === root) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not found');
    return;
  }

  fs.readFile(resolved, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': TYPES[path.extname(resolved)] || 'application/octet-stream',
      'Content-Length': data.length,
      'Cache-Control': 'no-cache',
      'X-Content-Type-Options': 'nosniff',
    });
    res.end(req.method === 'HEAD' ? undefined : data);
  });
}

async function handleRequest(req, res) {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch (err) {
    res.writeHead(400);
    res.end('Bad request');
    return;
  }

  if (url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, uptime_s: Math.round(process.uptime()) }));
    return;
  }

  if (url.pathname.startsWith('/api/')) {
    try {
      const handled = await api.handle(req, res, url);
      if (!handled) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: `unknown endpoint ${url.pathname}` }));
      }
    } catch (err) {
      if (!res.headersSent) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: String(err && err.message) }));
      }
    }
    return;
  }

  if (url.pathname === '/' || url.pathname === '/index.html') {
    try {
      const html = render.shell({ title: 'DataDonor — range dashboard' });
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(html);
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(`Template error: ${err.message}`);
    }
    return;
  }

  serveStatic(req, res, url.pathname);
}

const server = http.createServer(handleRequest);

if (require.main === module) {
  server.listen(cfg.port, cfg.bindHost, () => {
    console.log(`DataDonor dashboard on http://${cfg.bindHost}:${cfg.port}`);
    console.log(`  bind      : ${cfg.bindHost}:${cfg.port}`);
    console.log(`  datadonor : ${cfg.ddDb}`);
    console.log(`  food log  : ${cfg.healthDb}`);
  });

  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
      console.log(`${sig} received, closing server`);
      server.close(() => process.exit(0));
    });
  }
}

module.exports = { server, handleRequest, serveStatic, PUBLIC_DIR };
