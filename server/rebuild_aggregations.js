const { getDb } = require('./db');
const logger = require('./logger');

async function rebuildAggregations() {
    try {
        logger.info('Connecting to database and running migrations...');
        const db = await getDb();

        logger.info('Wiping existing daily_sync_stats table...');
        await db.run('DELETE FROM daily_sync_stats');

        logger.info('Rebuilding aggregations from health_metrics... This might take a moment depending on database size.');
        // Must match the ingestion path's bucketing (start_date.split('T')[0]); date()
        // would convert offsets to UTC and shift buckets relative to live inserts.
        const result = await db.run(`
            INSERT INTO daily_sync_stats (device_id, date_bucket, data_type, record_count)
            SELECT device_id, substr(start_date, 1, 10), data_type, COUNT(*)
            FROM health_metrics
            GROUP BY device_id, substr(start_date, 1, 10), data_type;
        `);

        logger.info(`Successfully rebuilt aggregations. Processed data into ${result.changes} daily buckets.`);
        logger.info('Done.');
        process.exit(0);
    } catch (err) {
        // Exit non-zero so a failed rebuild doesn't look like a success to callers.
        logger.error(`Failed to rebuild aggregations: ${err.message}`);
        process.exit(1);
    }
}

rebuildAggregations();
