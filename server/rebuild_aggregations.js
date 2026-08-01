const { getDb } = require('./db');
const logger = require('./logger');

async function rebuildAggregations() {
    try {
        logger.info('Connecting to database and running migrations...');
        const db = await getDb();

        logger.info('Wiping existing daily_sync_stats table...');
        await db.run('DELETE FROM daily_sync_stats');

        logger.info('Rebuilding aggregations from health_metrics... This might take a moment depending on database size.');
        const result = await db.run(`
            INSERT INTO daily_sync_stats (device_id, date_bucket, data_type, record_count)
            SELECT device_id, date(start_date), data_type, COUNT(*)
            FROM health_metrics
            GROUP BY device_id, date(start_date), data_type;
        `);

        logger.info(`Successfully rebuilt aggregations. Processed data into ${result.changes} daily buckets.`);
    } catch (err) {
        logger.error(`Failed to rebuild aggregations: ${err.message}`);
    } finally {
        logger.info('Done.');
        process.exit(0);
    }
}

rebuildAggregations();
