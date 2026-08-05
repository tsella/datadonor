const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
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

// Refuse to run with the placeholder key — otherwise a misconfigured deployment exposes
// the whole health archive to anyone who read the example config.
if (!config.security || !config.security.api_key ||
    config.security.api_key === 'REPLACE_ME_WITH_A_SECRET_KEY') {
    logger.error('❌ config.security.api_key is unset or still the default placeholder. Refusing to start.');
    process.exit(1);
}

const API_KEY_BUFFER = Buffer.from(config.security.api_key, 'utf8');

function isValidApiKey(token) {
    if (typeof token !== 'string' || token.length === 0) return false;
    const candidate = Buffer.from(token, 'utf8');
    // timingSafeEqual throws on length mismatch, so compare lengths first — the length of
    // the key is not the secret.
    if (candidate.length !== API_KEY_BUFFER.length) return false;
    return crypto.timingSafeEqual(candidate, API_KEY_BUFFER);
}

// Middleware: API Key Authentication
fastify.addHook('preHandler', (request, reply, done) => {
    const authHeader = request.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        logger.warn(`Unauthorized request from ${request.ip}`);
        return reply.status(401).send({ error: 'Missing or malformed Authorization header' });
    }
    const token = authHeader.slice('Bearer '.length).trim();
    if (!isValidApiKey(token)) {
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
        const countRow = await db.get('SELECT COUNT(*) as count FROM health_metrics WHERE device_id = ?', deviceId);
        const totalRecords = countRow ? countRow.count : 0;
        
        const checkpoints = {};
        for (const row of rows) {
            checkpoints[row.data_type] = row.anchor;
        }
        return { checkpoints, total_records: totalRecords };
    } catch (err) {
        logger.error(`Checkpoint inquiry failed: ${err.message}`);
        return reply.status(500).send({ error: 'Internal server error' });
    }
});

// Endpoint: C. Data Ingestion
//
// Writes are serialized because a single SQLite connection cannot nest transactions.
// The chain is kept alive with a trailing catch: if a link were ever left rejected,
// every later request would hang forever waiting on a .then that never runs.
let dbQueue = Promise.resolve();
let queueDepth = 0;
const MAX_QUEUE_DEPTH = 64;

function enqueueWrite(work) {
    if (queueDepth >= MAX_QUEUE_DEPTH) {
        return Promise.reject(Object.assign(new Error('Write queue is full'), { statusCode: 503 }));
    }
    queueDepth += 1;
    const result = dbQueue.then(work);
    // Keep the chain resolved regardless of this task's outcome, and never leave the
    // rejection unhandled.
    dbQueue = result.then(() => {}, () => {});
    return result.finally(() => { queueDepth -= 1; });
}

fastify.post('/api/v1/health-sync/post', async (request, reply) => {
    const { device_id, data, anchors, deleted_uuids } = request.body || {};

    if (!device_id || typeof device_id !== 'string' || !Array.isArray(data)) {
        return reply.status(400).send({ error: 'Invalid payload schema' });
    }

    // Every record must carry a uuid. SQLite treats NULLs as distinct in a UNIQUE index,
    // so ON CONFLICT(uuid) silently fails to dedupe them and re-syncs pile up duplicates.
    const missingUuid = data.findIndex((m) => !m || typeof m.uuid !== 'string' || m.uuid.length === 0);
    if (missingUuid !== -1) {
        return reply.status(400).send({
            error: `Every metric requires a non-empty uuid (index ${missingUuid} is missing one)`
        });
    }

    const invalidDate = data.findIndex((m) => typeof m.start_date !== 'string' || !m.start_date.includes('T'));
    if (invalidDate !== -1) {
        return reply.status(400).send({
            error: `Metric at index ${invalidDate} has a missing or malformed start_date`
        });
    }

    try {
        const result = await enqueueWrite(() => ingestPayload({ device_id, data, anchors, deleted_uuids }));
        return reply.status(201).send({ status: 'created', ...result });
    } catch (err) {
        if (err.statusCode === 503) {
            logger.warn(`Rejected ingestion from ${device_id}: write queue saturated`);
            return reply.status(503).send({ error: 'Server busy, retry shortly' });
        }
        logger.error(`Data ingestion failed: ${err.message}`);
        return reply.status(500).send({ error: 'Failed to ingest data' });
    }
});

async function ingestPayload({ device_id, data, anchors, deleted_uuids }) {
    const db = await getDb();

    // Register device if not exists
    await db.run('INSERT OR IGNORE INTO devices (device_id, name) VALUES (?, ?)', [device_id, 'Unknown iOS Device']);

    await db.run('BEGIN IMMEDIATE TRANSACTION');
    let inTransaction = true;

    try {
        const stmt = await db.prepare(`
            INSERT INTO health_metrics (device_id, data_type, start_date, end_date, value, unit, source, uuid, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO NOTHING
        `);

        // Count only rows that were actually inserted. Counting payload length instead
        // permanently inflates the stats whenever a payload is retried or re-sent, since
        // the insert above is idempotent but the stats UPSERT below is additive.
        const dailyCounts = {};
        let inserted = 0;
        let duplicates = 0;

        try {
            for (const metric of data) {
                const res = await stmt.run(
                    device_id,
                    metric.type,
                    metric.start_date,
                    metric.end_date,
                    String(metric.value),
                    metric.unit || null,
                    metric.source || null,
                    metric.uuid,
                    metric.metadata ? JSON.stringify(metric.metadata) : null
                );

                if (res && res.changes > 0) {
                    inserted += 1;
                    const dateStr = metric.start_date.split('T')[0];
                    if (!dailyCounts[dateStr]) dailyCounts[dateStr] = {};
                    dailyCounts[dateStr][metric.type] = (dailyCounts[dateStr][metric.type] || 0) + 1;
                } else {
                    duplicates += 1;
                }
            }
        } finally {
            await stmt.finalize();
        }

        // Handle deletions. Scoped by device_id so a payload cannot delete rows belonging
        // to another device.
        let deleted = 0;
        if (Array.isArray(deleted_uuids) && deleted_uuids.length > 0) {
            const deleteStmt = await db.prepare(
                `DELETE FROM health_metrics WHERE uuid = ? AND device_id = ?`);
            try {
                for (const uuid of deleted_uuids) {
                    if (typeof uuid !== 'string' || !uuid) continue;
                    const res = await deleteStmt.run(uuid, device_id);
                    if (res && res.changes > 0) deleted += res.changes;
                }
            } finally {
                await deleteStmt.finalize();
            }
        }

        const statsStmt = await db.prepare(`
            INSERT INTO daily_sync_stats (device_id, date_bucket, data_type, record_count)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(device_id, date_bucket, data_type)
            DO UPDATE SET record_count = record_count + excluded.record_count
        `);
        try {
            for (const [dateBucket, types] of Object.entries(dailyCounts)) {
                for (const [type, count] of Object.entries(types)) {
                    await statsStmt.run(device_id, dateBucket, type, count);
                }
            }
        } finally {
            await statsStmt.finalize();
        }

        // Update Sync Checkpoints
        if (anchors && typeof anchors === 'object') {
            const anchorStmt = await db.prepare(`
                INSERT INTO checkpoints (device_id, data_type, anchor)
                VALUES (?, ?, ?)
                ON CONFLICT(device_id, data_type)
                DO UPDATE SET anchor = excluded.anchor, updated_at = CURRENT_TIMESTAMP
            `);
            try {
                for (const [dataType, anchorValue] of Object.entries(anchors)) {
                    if (anchorValue) {
                        await anchorStmt.run(device_id, dataType, anchorValue);
                    }
                }
            } finally {
                await anchorStmt.finalize();
            }
        }

        await db.run('COMMIT');
        inTransaction = false;

        logger.info(
            `Ingested ${inserted} new metric(s) from device ${device_id} ` +
            `(${duplicates} duplicate(s) ignored, ${deleted} deleted)`);
        return { inserted, duplicates, deleted };
    } catch (err) {
        if (inTransaction) {
            try {
                await db.run('ROLLBACK');
            } catch (rollbackErr) {
                logger.error(`Rollback failed: ${rollbackErr.message}`);
            }
        }
        throw err;
    }
}

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
        // Snap back to the Monday starting each week. The previous
        // `date(x,'weekday 1','-7 days')` was off by one: 'weekday 1' is a no-op on a
        // Monday, so Mondays landed in the *previous* week's bucket while Tue-Sun landed
        // in the correct one, splitting every week across two buckets.
        const weekStart = `date(date_bucket, '-' || ((strftime('%w', date_bucket) + 6) % 7) || ' days')`;
        query = `SELECT ${weekStart} as date, data_type, SUM(record_count) as count
                 FROM daily_sync_stats WHERE device_id = ?
                 GROUP BY ${weekStart}, data_type`;
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
            if (type.includes('Exercise') || type.includes('Energy') || type.includes('Distance') || type.includes('Swimming') || type.includes('HKWorkout')) return 'Workouts';
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
        // Fail fast with the real error if migrations couldn't run, rather than serving
        // 500s from every handler.
        await getDb();

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
        logger.error(`Server failed to start: ${err.message}`);
        process.exit(1);
    }
};

start();
