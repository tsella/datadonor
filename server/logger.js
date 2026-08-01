const winston = require('winston');
const DailyRotateFile = require('winston-daily-rotate-file');
const path = require('path');
const { loadConfig } = require('./configManager');

// We have to load config carefully here to avoid early exits in tests, but it's fine for the main daemon.
const config = loadConfig();

const logFormat = winston.format.combine(
    winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
    winston.format.printf(({ timestamp, level, message }) => {
        return `[${timestamp}] [${level.toUpperCase()}] ${message}`;
    })
);

const transport = new DailyRotateFile({
    filename: path.join(__dirname, 'logs', 'datadonor-%DATE%.log'),
    datePattern: 'YYYY-MM-DD',
    zippedArchive: true,
    maxSize: '20m',
    maxFiles: `${config.logging.retention_days}d`
});

const logger = winston.createLogger({
    level: config.logging.level || 'info',
    format: logFormat,
    transports: [
        new winston.transports.Console({
            format: winston.format.combine(
                winston.format.colorize(),
                logFormat
            )
        }),
        transport
    ]
});

module.exports = logger;
