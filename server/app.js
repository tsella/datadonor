const express = require('express');
const https = require('https');
const fs = require('fs');
const path = require('path');
const Bonjour = require('bonjour-service');
const { loadConfig } = require('./configManager');
const logger = require('./logger');
const { getDb } = require('./db');

const config = loadConfig();
const app = express();

// Increase JSON payload limit to handle massive Apple Health backfills
app.use(express.json({ limit: '50mb' }));

// Middleware: API Key Authentication
app.use('/api/v1', (req, res, next) => {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        logger.warn(`Unauthorized request from ${req.ip}`);
        return res.status(401).json({ error: 'Missing or malformed Authorization header' });
    }
    const token = authHeader.split(' ')[1];
    if (token !== config.security.api_key) {
        logger.warn(`Invalid API Key used from ${req.ip}`);
        return res.status(403).json({ error: 'Forbidden: Invalid API Key' });
    }
    next();
});

// Endpoint: A. Livelihood & Validation
app.get('/api/v1/ping', (req, res) => {
    res.status(200).json({ status: 'ok', message: 'DataDonor server is online' });
});

// Endpoint: B. Checkpoint Inquiry
app.get('/api/v1/health-sync/checkpoint', async (req, res) => {
    const deviceId = req.headers['x-device-id'];
    if (!deviceId) {
        return res.status(400).json({ error: 'Missing X-Device-ID header' });
    }

    try {
        const db = await getDb();
        const rows = await db.all('SELECT data_type, anchor FROM checkpoints WHERE device_id = ?', deviceId);
        const checkpoints = {};
        for (const row of rows) {
            checkpoints[row.data_type] = row.anchor;
        }
        res.status(200).json({ checkpoints });
    } catch (err) {
        logger.error(`Checkpoint inquiry failed: ${err.message}`);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// Endpoint: C. Data Ingestion
app.post('/api/v1/health-sync/post', async (req, res) => {
    const { device_id, sync_timestamp, data } = req.body;
    
    if (!device_id || !Array.isArray(data)) {
        return res.status(400).json({ error: 'Invalid payload schema' });
    }

    try {
        const db = await getDb();
        
        // Register device if not exists
        await db.run('INSERT OR IGNORE INTO devices (device_id, name) VALUES (?, ?)', [device_id, 'Unknown iOS Device']);

        // Since node-sqlite3 (wrapper) does not have a native synchronous transaction loop like better-sqlite3,
        // we use a BEGIN TRANSACTION, execute all inserts, and COMMIT.
        await db.run('BEGIN TRANSACTION');
        
        const stmt = await db.prepare(`
            INSERT INTO health_metrics (device_id, data_type, start_date, end_date, value, unit, source)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        `);

        for (const metric of data) {
            await stmt.run(
                device_id,
                metric.type,
                metric.start_date,
                metric.end_date,
                String(metric.value),
                metric.unit || null,
                metric.source || null
            );
        }
        
        await stmt.finalize();
        await db.run('COMMIT');

        logger.info(`Successfully ingested ${data.length} metrics from device ${device_id}`);
        res.status(201).json({ status: 'created', inserted: data.length });
    } catch (err) {
        logger.error(`Data ingestion failed: ${err.message}`);
        // Attempt rollback if something failed
        try {
            const db = await getDb();
            await db.run('ROLLBACK');
        } catch (rollbackErr) {
            logger.error(`Rollback failed: ${rollbackErr.message}`);
        }
        res.status(500).json({ error: 'Failed to ingest data' });
    }
});

// Read SSL certs
let credentials = {};
try {
    const privateKey = fs.readFileSync(path.resolve(__dirname, config.server.ssl.key_path), 'utf8');
    const certificate = fs.readFileSync(path.resolve(__dirname, config.server.ssl.cert_path), 'utf8');
    credentials = { key: privateKey, cert: certificate };
} catch (err) {
    logger.error('❌ Failed to load SSL certificates. Make sure you generated them and specified the correct path in config.json.');
    logger.error(err.message);
    process.exit(1);
}

// Start HTTPS Server
const httpsServer = https.createServer(credentials, app);

httpsServer.listen(config.server.port, config.server.host, () => {
    logger.info(`🚀 DataDonor HTTPS Server running on https://${config.server.host}:${config.server.port}`);
    
    // Broadcast mDNS Bonjour service
    const bonjour = new Bonjour.Bonjour();
    bonjour.publish({ 
        name: 'DataDonor Backend', 
        type: 'datadonor', 
        protocol: 'tcp', 
        port: config.server.port 
    });
    logger.info('📡 mDNS _datadonor._tcp service is actively broadcasting');
});
