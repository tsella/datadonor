const fs = require('fs');
const path = require('path');
const Bonjour = require('bonjour-service');
const { loadConfig } = require('./configManager');
const logger = require('./logger');
const { getDb } = require('./db');

const config = loadConfig();

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

// Initialize Fastify
const fastify = require('fastify')({
    logger: false, // We use winston instead
    https: credentials,
    bodyLimit: 52428800 // 50MB payload limit
});

// Middleware: API Key Authentication
fastify.addHook('preHandler', (request, reply, done) => {
    const authHeader = request.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        logger.warn(`Unauthorized request from ${request.ip}`);
        return reply.status(401).send({ error: 'Missing or malformed Authorization header' });
    }
    const token = authHeader.split(' ')[1];
    if (token !== config.security.api_key) {
        logger.warn(`Invalid API Key used from ${request.ip}`);
        return reply.status(403).send({ error: 'Forbidden: Invalid API Key' });
    }
    done();
});

// Endpoint: A. Livelihood & Validation
fastify.get('/api/v1/ping', async (request, reply) => {
    return { status: 'ok', message: 'DataDonor server is online' };
});

// Endpoint: B. Checkpoint Inquiry
fastify.get('/api/v1/health-sync/checkpoint', async (request, reply) => {
    const deviceId = request.headers['x-device-id'];
    if (!deviceId) {
        return reply.status(400).send({ error: 'Missing X-Device-ID header' });
    }

    try {
        const db = await getDb();
        const rows = await db.all('SELECT data_type, anchor FROM checkpoints WHERE device_id = ?', deviceId);
        const checkpoints = {};
        for (const row of rows) {
            checkpoints[row.data_type] = row.anchor;
        }
        return { checkpoints };
    } catch (err) {
        logger.error(`Checkpoint inquiry failed: ${err.message}`);
        return reply.status(500).send({ error: 'Internal server error' });
    }
});

// Endpoint: C. Data Ingestion
let dbQueue = Promise.resolve();

fastify.post('/api/v1/health-sync/post', async (request, reply) => {
    const { device_id, sync_timestamp, data } = request.body;
    
    if (!device_id || !Array.isArray(data)) {
        return reply.status(400).send({ error: 'Invalid payload schema' });
    }

    // Queue DB writes to prevent SQLITE_ERROR: cannot start a transaction within a transaction
    return new Promise((resolve, reject) => {
        dbQueue = dbQueue.then(async () => {
            try {
                const db = await getDb();
        
        // Register device if not exists
        await db.run('INSERT OR IGNORE INTO devices (device_id, name) VALUES (?, ?)', [device_id, 'Unknown iOS Device']);

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
        
        // Aggregate and UPSERT into daily_sync_stats
        const dailyCounts = {};
        for (const metric of data) {
            const dateStr = metric.start_date.split('T')[0];
            if (!dailyCounts[dateStr]) dailyCounts[dateStr] = {};
            dailyCounts[dateStr][metric.type] = (dailyCounts[dateStr][metric.type] || 0) + 1;
        }

        const statsStmt = await db.prepare(`
            INSERT INTO daily_sync_stats (device_id, date_bucket, data_type, record_count)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(device_id, date_bucket, data_type)
            DO UPDATE SET record_count = record_count + excluded.record_count
        `);

        for (const [dateBucket, types] of Object.entries(dailyCounts)) {
            for (const [type, count] of Object.entries(types)) {
                await statsStmt.run(device_id, dateBucket, type, count);
            }
        }
        await statsStmt.finalize();

        await db.run('COMMIT');

        logger.info(`Successfully ingested ${data.length} metrics from device ${device_id}`);
        resolve(reply.status(201).send({ status: 'created', inserted: data.length }));
    } catch (err) {
        logger.error(`Data ingestion failed: ${err.message}`);
        try {
            const db = await getDb();
            await db.run('ROLLBACK');
        } catch (rollbackErr) {
            logger.error(`Rollback failed: ${rollbackErr.message}`);
        }
        resolve(reply.status(500).send({ error: 'Failed to ingest data' }));
    }
        });
    });
});

// Endpoint: D. Analytics Stats
fastify.get('/api/v1/health-sync/stats', async (request, reply) => {
    const deviceId = request.headers['x-device-id'];
    if (!deviceId) return reply.status(400).send({ error: 'Missing X-Device-ID header' });

    const timeScale = request.query.timeScale || 'days';
    const db = await getDb();
    
    let query = '';
    
    if (timeScale === 'days') {
        query = `SELECT date_bucket as date, data_type, SUM(record_count) as count 
                 FROM daily_sync_stats WHERE device_id = ? 
                 GROUP BY date_bucket, data_type`;
    } else if (timeScale === 'weeks') {
        query = `SELECT date(date_bucket, 'weekday 1', '-7 days') as date, data_type, SUM(record_count) as count 
                 FROM daily_sync_stats WHERE device_id = ? 
                 GROUP BY date(date_bucket, 'weekday 1', '-7 days'), data_type`;
    } else if (timeScale === 'months') {
        query = `SELECT date(date_bucket, 'start of month') as date, data_type, SUM(record_count) as count 
                 FROM daily_sync_stats WHERE device_id = ? 
                 GROUP BY date(date_bucket, 'start of month'), data_type`;
    } else {
        return reply.status(400).send({ error: 'Invalid timeScale' });
    }

    try {
        const rows = await db.all(query, deviceId);
        
        // Map raw identifiers to UI Buckets
        const mapTypeToBucket = (type) => {
            if (type.includes('HeartRate') || type.includes('SDNN')) return 'Heart Rate';
            if (type.includes('Step') || type.includes('Walking') || type.includes('Flights')) return 'Steps';
            if (type.includes('Sleep') || type.includes('Respiratory')) return 'Sleep';
            if (type.includes('Exercise') || type.includes('Energy') || type.includes('Distance') || type.includes('Swimming')) return 'Workouts';
            return 'Other';
        };

        const aggregated = {};
        for (const row of rows) {
            const bucket = mapTypeToBucket(row.data_type);
            if (bucket === 'Other') continue;
            
            const key = `${row.date}_${bucket}`;
            if (!aggregated[key]) {
                aggregated[key] = { date: row.date, type: bucket, count: 0 };
            }
            aggregated[key].count += row.count;
        }
        
        return { stats: Object.values(aggregated).sort((a, b) => a.date.localeCompare(b.date)) };
    } catch (err) {
        logger.error(`Failed to fetch stats: ${err.message}`);
        return reply.status(500).send({ error: 'Failed to fetch stats' });
    }
});

// Start Server
const start = async () => {
    try {
        await fastify.listen({ port: config.server.port, host: config.server.host });
        logger.info(`🚀 DataDonor Fastify HTTPS Server running on https://${config.server.host}:${config.server.port}`);
        
        // Broadcast mDNS Bonjour service
        const bonjour = new Bonjour.Bonjour();
        bonjour.publish({ 
            name: 'DataDonor Backend', 
            type: 'datadonor', 
            protocol: 'tcp', 
            port: config.server.port 
        });
        logger.info('📡 mDNS _datadonor._tcp service is actively broadcasting');
    } catch (err) {
        logger.error(err);
        process.exit(1);
    }
};

start();
