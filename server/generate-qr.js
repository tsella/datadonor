const fs = require('fs');
const path = require('path');
const qrcode = require('qrcode-terminal');

const configPath = path.join(__dirname, 'config.json');

if (!fs.existsSync(configPath)) {
    console.error("Error: config.json not found! Please run the server once to generate it.");
    process.exit(1);
}

try {
    const configData = fs.readFileSync(configPath, 'utf8');
    const config = JSON.parse(configData);
    const apiKey = config.security?.api_key;

    if (!apiKey || apiKey === "REPLACE_ME_WITH_A_SECRET_KEY") {
        console.error("Error: Please set a secure api_key in config.json before generating a QR code.");
        process.exit(1);
    }

    console.log("\nScan this QR code with the DataDonor iOS app to populate your API Key:\n");
    qrcode.generate(apiKey, { small: true }, function (qr) {
        console.log(qr);
    });

} catch (error) {
    console.error("Error reading config.json:", error.message);
    process.exit(1);
}
