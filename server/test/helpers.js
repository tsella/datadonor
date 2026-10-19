'use strict';
/**
 * Test harness for the ingest server.
 *
 * The tests drive the real process: a real config.json, a real socket, real TLS
 * and a throwaway SQLite file. `buildServer()` would be faster, but then the
 * TLS setup, the config gate and the startup order would go untested, and those
 * are where a misconfigured deployment actually breaks.
 *
 * DATADONOR_CONFIG and DATADONOR_LOG_DIR keep every run out of the live config
 * and the live log directory.
 */
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const https = require('https');

const APP = path.join(__dirname, '..', 'app.js');
const REPO_CERTS = path.join(__dirname, '..', 'certs');
const API_KEY = 'test-key-0123456789abcdef';

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dd-server-'));
}

/** A port nobody is listening on, taken by asking the kernel and closing it again. */
function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

/**
 * Repo certs when they exist, otherwise a throwaway pair. `server/certs/` is
 * gitignored, so CI has none; openssl makes a localhost pair on the spot.
 */
function ensureCerts(dir) {
  const local = { key: path.join(REPO_CERTS, 'key.pem'), cert: path.join(REPO_CERTS, 'cert.pem') };
  if (fs.existsSync(local.key) && fs.existsSync(local.cert)) return local;

  const key = path.join(dir, 'key.pem');
  const cert = path.join(dir, 'cert.pem');
  const { execFileSync } = require('child_process');
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-subj', '/CN=localhost', '-keyout', key, '-out', cert,
  ], { stdio: 'ignore' });
  return { key, cert };
}

function writeConfig(dir, { port, dbFile, limits }) {
  const certs = ensureCerts(dir);
  const config = {
    server: {
      host: '127.0.0.1',
      port,
      ssl: { key_path: certs.key, cert_path: certs.cert },
    },
    security: { api_key: API_KEY },
    database: { path: dbFile },
    logging: { level: 'warn', retention_days: 1 },
  };
  if (limits) config.limits = limits;

  const file = path.join(dir, 'config.json');
  fs.writeFileSync(file, JSON.stringify(config, null, 2));
  return { file, config };
}

function request(port, pathname, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        host: '127.0.0.1',
        port,
        path: pathname,
        method,
        rejectUnauthorized: false,
        headers,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const raw = Buffer.concat(chunks).toString('utf8');
          let json = null;
          try {
            json = JSON.parse(raw);
          } catch (err) {
            /* non-JSON bodies are reported as null */
          }
          resolve({ status: res.statusCode, json, raw });
        });
      },
    );
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

async function waitReady(port, child, timeoutMs = 15000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (child.exitCode !== null) {
      throw new Error(`server exited with code ${child.exitCode}`);
    }
    try {
      const res = await request(port, '/api/v1/ping', {
        headers: { Authorization: `Bearer ${API_KEY}` },
      });
      if (res.status === 200) return;
    } catch (err) {
      /* not listening yet */
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server did not become ready in time');
}

/** Start the server on a throwaway config. Returns handles plus a stop(). */
async function startServer({ limits } = {}) {
  const dir = tempDir();
  const port = await freePort();
  const dbFile = path.join(dir, 'datadonor.sqlite');
  const { file } = writeConfig(dir, { port, dbFile, limits });

  const child = spawn(process.execPath, [APP], {
    env: {
      ...process.env,
      DATADONOR_CONFIG: file,
      DATADONOR_LOG_DIR: path.join(dir, 'logs'),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let output = '';
  child.stdout.on('data', (d) => { output += d.toString(); });
  child.stderr.on('data', (d) => { output += d.toString(); });

  const stop = () =>
    new Promise((resolve) => {
      if (child.exitCode !== null) return resolve();
      child.once('exit', () => resolve());
      child.kill('SIGTERM');
      setTimeout(() => {
        if (child.exitCode === null) child.kill('SIGKILL');
      }, 2000).unref();
    });

  try {
    await waitReady(port, child);
  } catch (err) {
    await stop();
    throw new Error(`${err.message}\n--- server output ---\n${output}`);
  }

  return {
    dir,
    port,
    dbFile,
    apiKey: API_KEY,
    child,
    output: () => output,
    stop,
    call: (pathname, opts = {}) =>
      request(port, pathname, {
        ...opts,
        headers: { Authorization: `Bearer ${API_KEY}`, ...(opts.headers || {}) },
      }),
  };
}

/** A payload shaped like the client's: five records on one day. */
function samplePayload(deviceId = 'device-a', day = '2026-10-17') {
  const types = [
    'HKQuantityTypeIdentifierStepCount',
    'HKQuantityTypeIdentifierHeartRate',
    'HKQuantityTypeIdentifierActiveEnergyBurned',
    'HKCategoryTypeIdentifierSleepAnalysis',
    'HKWorkoutTypeIdentifier',
  ];
  return {
    device_id: deviceId,
    data: types.map((type, i) => ({
      uuid: `${deviceId}-uuid-${i}`,
      type,
      start_date: `${day}T0${i}:00:00Z`,
      end_date: `${day}T0${i}:05:00Z`,
      value: String(100 + i),
      unit: 'count',
      source: 'Tom\u2019s Apple\u00a0Watch',
    })),
    anchors: { HKQuantityTypeIdentifierStepCount: 'anchor-1' },
    deleted_uuids: [],
  };
}

module.exports = { startServer, samplePayload, request, freePort, API_KEY, tempDir };
