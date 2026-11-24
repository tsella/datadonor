'use strict';
/**
 * Default config generation permissions.
 *
 * config.json holds the server API key, so when configManager generates a default
 * template on first run it must be created owner-read/write only (0600).
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { tempDir } = require('./helpers');

const CONFIG_MANAGER = path.join(__dirname, '..', 'configManager.js');

test('default config.json is created with 0o600 permissions', () => {
  const dir = tempDir();
  const cfgPath = path.join(dir, 'config.json');

  const res = spawnSync(
    process.execPath,
    ['-e', `require(${JSON.stringify(CONFIG_MANAGER)}).loadConfig()`],
    {
      env: { ...process.env, DATADONOR_CONFIG: cfgPath },
      encoding: 'utf8',
    },
  );

  assert.strictEqual(res.status, 1, 'exits non-zero after generating default config');
  assert.ok(fs.existsSync(cfgPath), 'default config.json was written');

  const mode = fs.statSync(cfgPath).mode & 0o777;
  assert.strictEqual(
    mode,
    0o600,
    `expected config.json mode 0o600, got 0o${mode.toString(8)}`,
  );

  const parsed = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  assert.strictEqual(parsed.security.api_key, 'REPLACE_ME_WITH_A_SECRET_KEY');
});
