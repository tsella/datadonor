/**
 * Kept so an old habit still works: `cd server && pm2 start ecosystem.config.js`.
 * The process definitions live in the repository root file, because the
 * dashboard is a second service and one file has to own both.
 */
module.exports = require('../ecosystem.config.js');
