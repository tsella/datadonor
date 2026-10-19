const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
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

/**
 * Analytics buckets for /api/v1/health-sync/stats.
 *
 * An explicit table, not substring matching. The previous version tested
 * `includes('HeartRate')` first, then 'Step'/'Walking'/'Flights', and worked only
 * because of that order: a new type whose name contains two of those words lands
 * in whichever check comes first. A type absent here is 'Other', which the route
 * drops from the response instead of attributing it to a bucket.
 */
const TYPE_BUCKETS = {
    HKQuantityTypeIdentifierHeartRate: 'Heart Rate',
    HKQuantityTypeIdentifierRestingHeartRate: 'Heart Rate',
    HKQuantityTypeIdentifierWalkingHeartRateAverage: 'Heart Rate',
    HKQuantityTypeIdentifierHeartRateVariabilitySDNN: 'Heart Rate',
    HKQuantityTypeIdentifierHeartRateRecoveryOneMinute: 'Heart Rate',
    HKQuantityTypeIdentifierStepCount: 'Steps',
    HKQuantityTypeIdentifierDistanceWalkingRunning: 'Steps',
    HKQuantityTypeIdentifierWalkingSpeed: 'Steps',
    HKQuantityTypeIdentifierWalkingStepLength: 'Steps',
    HKQuantityTypeIdentifierWalkingAsymmetryPercentage: 'Steps',
    HKQuantityTypeIdentifierWalkingDoubleSupportPercentage: 'Steps',
    HKQuantityTypeIdentifierAppleWalkingSteadiness: 'Steps',
    HKQuantityTypeIdentifierFlightsClimbed: 'Steps',
    HKCategoryTypeIdentifierSleepAnalysis: 'Sleep',
    HKQuantityTypeIdentifierRespiratoryRate: 'Sleep',
    HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances: 'Sleep',
    HKWorkoutTypeIdentifier: 'Workouts',
    HKQuantityTypeIdentifierAppleExerciseTime: 'Workouts',
    HKQuantityTypeIdentifierActiveEnergyBurned: 'Workouts',
    HKQuantityTypeIdentifierBasalEnergyBurned: 'Workouts',
    HKQuantityTypeIdentifierDistanceCycling: 'Workouts',
    HKQuantityTypeIdentifierDistanceSwimming: 'Workouts',
    HKQuantityTypeIdentifierDistanceDownhillSnowSports: 'Workouts',
    HKQuantityTypeIdentifierSwimmingStrokeCount: 'Workouts',
    HKQuantityTypeIdentifierPhysicalEffort: 'Workouts',
    HKQuantityTypeIdentifierWorkoutEffortScore: 'Workouts',
    HKQuantityTypeIdentifierEstimatedWorkoutEffortScore: 'Workouts',
};

function bucketForType(type) {
    return TYPE_BUCKETS[type] || 'Other';
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

// Accept gzip-compressed request bodies. The sync payload repeats `type` and `source`
// verbatim on every record, so the client compresses it; Fastify's default JSON parser
// only handles plain text, hence an explicit parser keyed off Content-Encoding.
//
// The size guard applies to the *decompressed* body: bodyLimit bounds what arrives on the
// wire, which a compressed payload can vastly exceed once expanded. Overridable from config
// so a test can prove the guard rejects a small bomb instead of allocating 200 MB.
const MAX_DECOMPRESSED_BYTES =
    (config.limits && config.limits.maxDecompressedBytes) || 200 * 1024 * 1024;

fastify.addContentTypeParser(
    'application/json',
    { parseAs: 'buffer' },
    function (request, body, done) {
        const encoding = (request.headers['content-encoding'] || 'identity').toLowerCase().trim();

        if (encoding === 'identity' || encoding === '') {
            try {
                done(null, JSON.parse(body.toString('utf8')));
            } catch (err) {
                err.statusCode = 400;
                done(err);
            }
            return;
        }

        if (encoding !== 'gzip') {
            const err = new Error(`Unsupported Content-Encoding: ${encoding}`);
            err.statusCode = 415;
            return done(err);
        }

        zlib.gunzip(body, { maxOutputLength: MAX_DECOMPRESSED_BYTES }, (err, inflated) => {
            if (err) {
                logger.warn(`Failed to gunzip request body: ${err.message}`);
                err.statusCode = 400;
                return done(err);
            }
            try {
                done(null, JSON.parse(inflated.toString('utf8')));
            } catch (parseErr) {
                parseErr.statusCode = 400;
                done(parseErr);
            }
        });
    }
);

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
        // Sum daily_sync_stats via its (device_id, ...) primary-key index instead of
        // running COUNT(*) on health_metrics (which has no device_id index and scans
        // millions of rows).
        const countRow = await db.get(
            'SELECT COALESCE(SUM(record_count), 0) as count FROM daily_sync_stats WHERE device_id = ?',
            deviceId
        );
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

const ISO_DATE_PREFIX_RE = /^\d{4}-\d{2}-\d{2}T/;

fastify.post('/api/v1/health-sync/post', async (request, reply) => {
    const { device_id, data, anchors, deleted_uuids } = request.body || {};

    if (!device_id || typeof device_id !== 'string' || !Array.isArray(data)) {
        return reply.status(400).send({ error: 'Invalid payload schema' });
    }

    // Validate all required fields in a single pass. Every record must carry a uuid
    // (SQLite treats NULLs as distinct in a UNIQUE index, so ON CONFLICT(uuid) silently
    // fails to dedupe them), an ISO start_date (for 10-char YYYY-MM-DD bucketing), and
    // non-null type/end_date/value (to avoid NOT NULL 500s or storing literal "undefined").
    for (let i = 0; i < data.length; i += 1) {
        const m = data[i];
        if (!m || typeof m.uuid !== 'string' || m.uuid.length === 0) {
            return reply.status(400).send({
                error: `Every metric requires a non-empty uuid (index ${i} is missing one)`
            });
        }
        if (typeof m.type !== 'string' || m.type.length === 0) {
            return reply.status(400).send({
                error: `Metric at index ${i} has a missing or malformed type`
            });
        }
        if (typeof m.start_date !== 'string' || !ISO_DATE_PREFIX_RE.test(m.start_date)) {
            return reply.status(400).send({
                error: `Metric at index ${i} has a missing or malformed start_date`
            });
        }
        if (typeof m.end_date !== 'string' || m.end_date.length === 0) {
            return reply.status(400).send({
                error: `Metric at index ${i} has a missing or malformed end_date`
            });
        }
        if (m.value === undefined || m.value === null) {
            return reply.status(400).send({
                error: `Metric at index ${i} has a missing value`
            });
        }
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

const knownDevices = new Set();

async function ingestPayload({ device_id, data, anchors, deleted_uuids }) {
    const db = await getDb();

    await db.run('BEGIN IMMEDIATE TRANSACTION');
    let inTransaction = true;

    try {
        // Register device inside the write transaction, skipping the statement once known.
        if (!knownDevices.has(device_id)) {
            await db.run('INSERT OR IGNORE INTO devices (device_id, name) VALUES (?, ?)', [device_id, 'Unknown iOS Device']);
        }

        // Count only rows that were actually inserted. Counting payload length instead
        // permanently inflates the stats whenever a payload is retried or re-sent, since
        // the insert is idempotent but the stats UPSERT below is additive.
        const dailyCounts = {};
        let inserted = 0;
        let duplicates = 0;

        // Drop duplicates within the payload once upfront so chunks only carry unique UUIDs.
        const seen = new Set();
        const uniqueData = [];
        for (const metric of data) {
            if (seen.has(metric.uuid)) {
                duplicates += 1;
                continue;
            }
            seen.add(metric.uuid);
            uniqueData.push(metric);
        }

        // Insert in multi-row chunks using `ON CONFLICT(uuid) DO NOTHING RETURNING` so SQLite
        // resolves duplicates and returns the exact inserted (data_type, date_bucket) pairs
        // in a single B-tree pass, without a separate SELECT pre-probe per chunk.
        // 500 rows * 9 columns = 4500 bind parameters (well under SQLite 3.32+'s 32766 limit).
        const COLUMNS_PER_ROW = 9;
        const CHUNK_ROWS = 500;
        const rowPlaceholder = `(${new Array(COLUMNS_PER_ROW).fill('?').join(',')})`;

        for (let offset = 0; offset < uniqueData.length; offset += CHUNK_ROWS) {
            const chunk = uniqueData.slice(offset, offset + CHUNK_ROWS);
            const values = [];
            for (const metric of chunk) {
                values.push(
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
            }

            const insertedRows = await db.all(
                `INSERT INTO health_metrics
                    (device_id, data_type, start_date, end_date, value, unit, source, uuid, metadata)
                 VALUES ${new Array(chunk.length).fill(rowPlaceholder).join(',')}
                 ON CONFLICT(uuid) DO NOTHING
                 RETURNING data_type, substr(start_date, 1, 10) AS date_bucket`,
                values
            );

            inserted += insertedRows.length;
            duplicates += chunk.length - insertedRows.length;

            for (const row of insertedRows) {
                if (!dailyCounts[row.date_bucket]) dailyCounts[row.date_bucket] = {};
                dailyCounts[row.date_bucket][row.data_type] =
                    (dailyCounts[row.date_bucket][row.data_type] || 0) + 1;
            }
        }

        // Handle deletions in chunks. Scoped by device_id so a payload cannot delete rows
        // belonging to another device, and RETURNING gives the exact buckets to decrement
        // in daily_sync_stats.
        let deleted = 0;
        const deletedCounts = {};
        if (Array.isArray(deleted_uuids) && deleted_uuids.length > 0) {
            const validUuids = deleted_uuids.filter((u) => typeof u === 'string' && u.length > 0);
            const DELETE_CHUNK = 500;
            for (let offset = 0; offset < validUuids.length; offset += DELETE_CHUNK) {
                const chunk = validUuids.slice(offset, offset + DELETE_CHUNK);
                const deletedRows = await db.all(
                    `DELETE FROM health_metrics
                      WHERE device_id = ? AND uuid IN (${new Array(chunk.length).fill('?').join(',')})
                     RETURNING data_type, substr(start_date, 1, 10) AS date_bucket`,
                    [device_id, ...chunk]
                );
                deleted += deletedRows.length;
                for (const row of deletedRows) {
                    if (!deletedCounts[row.date_bucket]) deletedCounts[row.date_bucket] = {};
                    deletedCounts[row.date_bucket][row.data_type] =
                        (deletedCounts[row.date_bucket][row.data_type] || 0) + 1;
                }
            }
        }

        // Batch-upsert positive daily_sync_stats increments.
        const statsValues = [];
        for (const [dateBucket, types] of Object.entries(dailyCounts)) {
            for (const [type, count] of Object.entries(types)) {
                statsValues.push(device_id, dateBucket, type, count);
            }
        }
        const STATS_CHUNK_PARAMS = 500 * 4;
        for (let offset = 0; offset < statsValues.length; offset += STATS_CHUNK_PARAMS) {
            const chunk = statsValues.slice(offset, offset + STATS_CHUNK_PARAMS);
            const rowCount = chunk.length / 4;
            await db.run(
                `INSERT INTO daily_sync_stats (device_id, date_bucket, data_type, record_count)
                 VALUES ${new Array(rowCount).fill('(?,?,?,?)').join(',')}
                 ON CONFLICT(device_id, date_bucket, data_type)
                 DO UPDATE SET record_count = record_count + excluded.record_count`,
                chunk
            );
        }

        // Decrement daily_sync_stats for any deleted records.
        for (const [dateBucket, types] of Object.entries(deletedCounts)) {
            for (const [type, count] of Object.entries(types)) {
                await db.run(
                    `UPDATE daily_sync_stats
                        SET record_count = MAX(0, record_count - ?)
                      WHERE device_id = ? AND date_bucket = ? AND data_type = ?`,
                    [count, device_id, dateBucket, type]
                );
            }
        }

        // Batch-upsert Sync Checkpoints.
        if (anchors && typeof anchors === 'object') {
            const anchorValues = [];
            for (const [dataType, anchorValue] of Object.entries(anchors)) {
                if (anchorValue) {
                    anchorValues.push(device_id, dataType, anchorValue);
                }
            }
            const ANCHOR_CHUNK_PARAMS = 500 * 3;
            for (let offset = 0; offset < anchorValues.length; offset += ANCHOR_CHUNK_PARAMS) {
                const chunk = anchorValues.slice(offset, offset + ANCHOR_CHUNK_PARAMS);
                const rowCount = chunk.length / 3;
                await db.run(
                    `INSERT INTO checkpoints (device_id, data_type, anchor)
                     VALUES ${new Array(rowCount).fill('(?,?,?)').join(',')}
                     ON CONFLICT(device_id, data_type)
                     DO UPDATE SET anchor = excluded.anchor, updated_at = CURRENT_TIMESTAMP`,
                    chunk
                );
            }
        }

        await db.run('COMMIT');
        inTransaction = false;
        knownDevices.add(device_id);

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
        // (device_id, date_bucket, data_type) is already the primary key of daily_sync_stats,
        // so rows are already unique and ordered by date_bucket without a GROUP BY.
        query = `SELECT date_bucket as date, data_type, record_count as count 
                 FROM daily_sync_stats
                 WHERE device_id = ? AND record_count > 0`;
    } else if (timeScale === 'weeks') {
        // Snap back to the Monday starting each week. The previous
        // `date(x,'weekday 1','-7 days')` was off by one: 'weekday 1' is a no-op on a
        // Monday, so Mondays landed in the *previous* week's bucket while Tue-Sun landed
        // in the correct one, splitting every week across two buckets.
        const weekStart = `date(date_bucket, '-' || ((strftime('%w', date_bucket) + 6) % 7) || ' days')`;
        query = `SELECT ${weekStart} as date, data_type, SUM(record_count) as count
                 FROM daily_sync_stats
                 WHERE device_id = ? AND record_count > 0
                 GROUP BY ${weekStart}, data_type`;
    } else if (timeScale === 'months') {
        query = `SELECT date(date_bucket, 'start of month') as date, data_type, SUM(record_count) as count 
                 FROM daily_sync_stats
                 WHERE device_id = ? AND record_count > 0
                 GROUP BY date(date_bucket, 'start of month'), data_type`;
    } else {
        return reply.status(400).send({ error: 'Invalid timeScale' });
    }

    try {
        const rows = await db.all(query, deviceId);
        
        // Map raw identifiers to UI Buckets
        const mapTypeToBucket = (type) => bucketForType(type);

        const aggregated = {};
        for (const row of rows) {
            const bucket = mapTypeToBucket(row.data_type);
            if (bucket === 'Other' || !row.count) continue;
            
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

let bonjour;
let shuttingDown = false;

async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info(`Received ${signal}, shutting down gracefully...`);
    try {
        if (bonjour) {
            await new Promise((resolve) => bonjour.unpublishAll(() => {
                bonjour.destroy();
                resolve();
            }));
        }
        await fastify.close();
        await dbQueue;
        const db = await getDb();
        await db.close();
    } catch (err) {
        logger.error(`Error during shutdown: ${err.message}`);
    }
    process.exit(0);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

// Start Server
const start = async () => {
    try {
        // Fail fast with the real error if migrations couldn't run, rather than serving
        // 500s from every handler.
        await getDb();

        await fastify.listen({ port: config.server.port, host: config.server.host });
        logger.info(`🚀 DataDonor Fastify HTTPS Server running on https://${config.server.host}:${config.server.port}`);
        
        // Broadcast mDNS Bonjour service
        bonjour = new Bonjour.Bonjour();
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
