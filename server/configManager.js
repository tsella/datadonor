const fs = require('fs');
const path = require('path');

const CONFIG_PATH = process.env.DATADONOR_CONFIG || path.join(__dirname, 'config.json');

const DEFAULT_CONFIG = {
    server: {
        host: '0.0.0.0',
        port: 8443,
        ssl: {
            key_path: './certs/key.pem',
            cert_path: './certs/cert.pem'
        }
    },
    security: {
        api_key: 'REPLACE_ME_WITH_A_SECRET_KEY'
    },
    database: {
        path: './data/datadonor.sqlite'
    },
    logging: {
        level: 'info',
        retention_days: 7
    }
};

function loadConfig() {
    if (!fs.existsSync(CONFIG_PATH)) {
        console.warn('⚠️ No config.json found. Generating a default configuration file.');
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(DEFAULT_CONFIG, null, 2), { encoding: 'utf-8', mode: 0o600 });
        try {
            fs.chmodSync(CONFIG_PATH, 0o600);
        } catch (err) {
            // Best-effort on filesystems that do not support POSIX chmod.
        }
        console.warn('⚠️ Please edit config.json to set your api_key and SSL paths, then restart the server.');
        process.exit(1);
    }
    
    try {
        const raw = fs.readFileSync(CONFIG_PATH, 'utf-8');
        return JSON.parse(raw);
    } catch (err) {
        console.error('❌ Failed to parse config.json. Please ensure it is valid JSON.');
        process.exit(1);
    }
}

module.exports = { loadConfig };
