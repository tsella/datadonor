/**
 * PM2 process file for the whole project. One command starts both halves:
 *
 *   pm2 start ecosystem.config.js
 *   pm2 save
 *
 * The ingest server and the dashboard are separate processes on purpose. The
 * dashboard only ever opens the databases read-only, so a crash or a restart
 * there cannot interrupt a sync.
 */
const path = require('path');

module.exports = {
  apps: [
    {
      name: 'datadonor-server',
      cwd: path.join(__dirname, 'server'),
      script: 'app.js',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '1G',
      env: {
        NODE_ENV: 'production',
      },
    },
    {
      name: 'datadonor-dashboard',
      cwd: path.join(__dirname, 'dashboard'),
      script: 'app.js',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
      env: {
        NODE_ENV: 'production',
      },
    },
  ],
};
