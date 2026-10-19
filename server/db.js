const sqlite3 = require('sqlite3').verbose();
const { open } = require('sqlite');
const path = require('path');
const { loadConfig } = require('./configManager');
const logger = require('./logger');

const config = loadConfig();
const dbPath = path.resolve(__dirname, config.database.path);

let dbPromise;

async function setupDatabase() {
    logger.info('Initializing SQLite database...');
    
    const db = await open({
        filename: dbPath,
        driver: sqlite3.Database
    });
    
    // Enable WAL mode for better concurrency and performance
    await db.exec('PRAGMA journal_mode = WAL');
    // NORMAL is the standard companion to WAL: it drops the per-commit fsync that FULL
    // forces, which dominates ingest cost on large batched syncs. The durability window
    // it opens is loss of the most recent commits on an OS crash or power cut — not
    // corruption, and not on a process crash. Worth it here; the client re-sends anything
    // whose anchor did not advance.
    await db.exec('PRAGMA synchronous = NORMAL');
    // Wait up to 5s on lock contention (e.g. rebuild-stats) instead of failing immediately
    // with SQLITE_BUSY, enforce declared FOREIGN KEY constraints, and keep temporary
    // B-trees (GROUP BY) in memory.
    await db.exec('PRAGMA busy_timeout = 5000');
    await db.exec('PRAGMA foreign_keys = ON');
    await db.exec('PRAGMA temp_store = MEMORY');
    
    logger.info('Running database migrations...');
    
    await db.exec(`
        CREATE TABLE IF NOT EXISTS devices (
            device_id TEXT PRIMARY KEY,
            name TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
    `);

    await db.exec(`
        CREATE TABLE IF NOT EXISTS checkpoints (
            device_id TEXT,
            data_type TEXT,
            anchor TEXT NOT NULL,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (device_id, data_type),
            FOREIGN KEY (device_id) REFERENCES devices(device_id)
        );
    `);

    await db.exec(`
        CREATE TABLE IF NOT EXISTS health_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT UNIQUE,
            device_id TEXT,
            data_type TEXT NOT NULL,
            start_date DATETIME NOT NULL,
            end_date DATETIME NOT NULL,
            value TEXT NOT NULL,
            unit TEXT,
            source TEXT,
            metadata JSON,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (device_id) REFERENCES devices(device_id)
        );
    `);

    await db.exec(`
        CREATE TABLE IF NOT EXISTS daily_sync_stats (
            device_id TEXT,
            date_bucket TEXT,
            data_type TEXT,
            record_count INTEGER DEFAULT 0,
            PRIMARY KEY (device_id, date_bucket, data_type),
            FOREIGN KEY (device_id) REFERENCES devices(device_id)
        );
    `);

    await db.exec(`CREATE INDEX IF NOT EXISTS idx_metrics_type_date ON health_metrics(data_type, start_date);`);

    // Backfill summary table if needed. Probe with LIMIT 1 rather than COUNT(*) so
    // startup does not scan the entire table on every boot.
    const statsHasRows = await db.get(`SELECT 1 FROM daily_sync_stats LIMIT 1`);
    if (!statsHasRows) {
        const metricsHasRows = await db.get(`SELECT 1 FROM health_metrics LIMIT 1`);
        if (metricsHasRows) {
            logger.info('Backfilling daily_sync_stats from existing health_metrics... This might take a moment.');
            // substr(start_date,1,10) matches how ingestion buckets (start_date.split('T')[0]).
            // date() would normalize offsets to UTC and shift buckets by a day relative to
            // the live path for any client that sends non-UTC timestamps.
            await db.exec(`
                INSERT INTO daily_sync_stats (device_id, date_bucket, data_type, record_count)
                SELECT device_id, substr(start_date, 1, 10), data_type, COUNT(*)
                FROM health_metrics
                GROUP BY device_id, substr(start_date, 1, 10), data_type;
            `);
            logger.info('Backfill complete!');
        }
    }

    logger.info('Database migrations completed successfully.');
    return db;
}

// Start DB setup immediately, but let the rejection propagate. Calling process.exit() in a
// catch here used to leave getDb() resolving to `undefined` for the interval before the
// process actually died, turning the real error into a confusing TypeError in every handler.
dbPromise = setupDatabase();
// Avoid an unhandled rejection warning if nothing awaits it before startup fails.
dbPromise.catch(() => {});

module.exports = {
    getDb: () => dbPromise
};
