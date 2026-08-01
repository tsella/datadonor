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

    // Create index if not exists
    const indexCheck = await db.get(`
        SELECT count(*) as count FROM sqlite_master WHERE type='index' AND name='idx_metrics_type_date';
    `);

    if (indexCheck.count === 0) {
        await db.exec(`CREATE INDEX idx_metrics_type_date ON health_metrics(data_type, start_date);`);
    }

    logger.info('Database migrations completed successfully.');
    return db;
}

// Start DB setup immediately
dbPromise = setupDatabase().catch(err => {
    logger.error(`Database setup failed: ${err.message}`);
    process.exit(1);
});

module.exports = {
    getDb: () => dbPromise
};
