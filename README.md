# DataDonor

DataDonor is an iOS application designed to run in the background, collect all available Apple Health data via HealthKit, and securely transmit it to a local server. The app features mDNS server discovery, explicit server approval with certificate pinning, and automatic background syncs to ensure your health data remains securely stored on your own local infrastructure.

## Supported Health Data
DataDonor comprehensively extracts both time-series quantity samples and category events. Currently supported metrics include:
- **Cardiovascular & Vitals**: Heart Rate, Resting Heart Rate, Walking Heart Rate Average, Heart Rate Variability (HRV), VO2 Max, Oxygen Saturation (SpO2), Blood Pressure (Systolic/Diastolic), Body Mass, Height, BMI, Body Fat Percentage, Lean Body Mass.
- **Activity & Mobility**: Step Count, Distance (Walking/Running, Cycling, Swimming), Swimming Stroke Count, Flights Climbed, Active/Basal Energy Burned, Exercise Time, Stand Time, Walking Asymmetry, Step Length, Double Support Time, Walking Speed.
- **Sleep & Environment**: Sleep Stages (Analysis), Respiratory Rate, Wrist Temperature, Environmental Audio Exposure, Time in Daylight.
- **Events & Characteristics**: Mindful Sessions, Menstrual Flow, Irregular Rhythm Notifications, High/Low Heart Rate Events.

*(Note: Static characteristic data like Date of Birth and Biological Sex require separate extraction pathways and can be added on request.)*

## Features
- **HealthKit Integration**: Broad-net extraction engine that securely reads and correctly standardizes units for over 35 distinct HealthKit metrics.
- **Background URLSession**: Ensures that massive historical data payloads successfully upload even if the app is placed in the background. Uploads are acknowledged by the server before the sync checkpoint advances, so a failed upload is retried rather than skipped.
- **Automatic Background Sync**: Registers a periodic background refresh task and observes HealthKit for new samples, syncing without needing the app opened.
- **Approved Servers & Certificate Pinning**: Servers discovered over mDNS require explicit approval. On approval the server's certificate is pinned, so self-signed certificates work while a substituted certificate is rejected.

## API Key Configuration & QR Scanner
To securely link your iOS client to your backend server, DataDonor uses an API Key. Instead of manually typing long alphanumeric strings on your iPhone, you can quickly scan a QR code!

1. Open your terminal and navigate to the `server/` directory.
2. Run `npm run qr` (or `node generate-qr.js`).
3. Your server will read the `API_KEY` you defined in `server/config.json` and print a large QR code directly in your terminal.
4. On the iOS DataDonor app, tap the QR code icon next to the API Key text field and point your camera at the terminal screen to instantly configure it!

## Repository layout

```
client/              SwiftUI app: HealthKit extraction, background sync, pinning
server/              Fastify HTTPS ingest API and SQLite storage
dashboard/           Read-only web dashboard over the archive and the meal log
ecosystem.config.js  PM2 process file for both Node services
```

The dashboard is a consumer, never a writer: it opens both databases with
`OPEN_READONLY` and a write attempt throws instead of landing.

## Running

```
cd server && npm install        # then create config.json from config.json.example
cd dashboard && npm install
pm2 start ecosystem.config.js   # starts the ingest server and the dashboard
```

`server/config.json` must define `security.api_key`; the server refuses to start
while the example value is in place. Relative paths in that file resolve against
`server/`. Two environment variables override the defaults, mostly for tests:
`DATADONOR_CONFIG` (config file path) and `DATADONOR_LOG_DIR` (log directory).

Some npm configurations block install scripts. If `require('sqlite3')` fails with
a missing binding, run `npm install-scripts approve sqlite3` or
`npm rebuild sqlite3 --foreground-scripts` in that directory.

## Tests

```
cd server && npm test        # auth, ingest idempotency, gzip limits, buckets
cd dashboard && npm test     # unit tests against a throwaway database
```

Both suites are self-contained and run in CI.

## Background sync

Three wake paths, fastest first:

- HealthKit observers on steps, heart rate, active energy, resting HR, HRV, body mass,
  sleep and workouts. Each wake syncs the type that changed inside a
  `beginBackgroundTask`, because the callback's own runtime is a few seconds.
- `BGAppRefreshTask` (`la.tsel.datadonor.backgroundSync`) for the periodic delta.
- `BGProcessingTask` (`la.tsel.datadonor.fullSync`) for the full 46-type sweep, which
  does not fit a refresh window.

iOS decides when a background task runs; the `earliestBeginDate` values are floors, not a
cadence. Observers are process-bound and are registered on every launch, so a force-quit
stops them until the app is opened again.

The refresh request asks for a five-minute floor. A sync failure alert is sent only after
three consecutive runs fail, and a clean run clears the count; the streak and the last alert
time live in `UserDefaults` so they survive the fresh process a background run usually gets.

To trigger a task by hand in Xcode, pause the debugger and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"la.tsel.datadonor.backgroundSync"]
```

Uploads are visible on the server: `server/logs/datadonor-*.log` logs `Ingested N new
metric(s)` per batch, and a run that finds nothing new still posts a heartbeat.

## Server Specification
This app requires a backend server to receive the data. See the `server_specification.md` document for the full JSON payload specifications, checkpoint syncing mechanics, and endpoint requirements.

## Data Analysis Examples
Want to visualize the data once it hits the database? We've provided a complete Python guide on extracting, formatting, and plotting your health metrics (like Heart Rate overlaid with Sleep and Exercise times) in the [`data_analysis_examples.md`](data_analysis_examples.md) document.

## Deployment to Personal Device
To run DataDonor on your personal iPhone, you must build and deploy it directly from Xcode. Please note that Apple requires an Apple Developer account to deploy custom apps that utilize HealthKit entitlements to a physical device.

1. Register for an [Apple Developer Account](https://developer.apple.com/) (a free tier account is sufficient, though the app will expire every 7 days and require a rebuild. A paid account allows 1-year provisioning).
2. Open `client/DataDonor.xcodeproj` in Xcode.
3. In the project navigator, select the `DataDonor` target, navigate to the **Signing & Capabilities** tab, and select your Personal Team from the dropdown.
4. Ensure the **HealthKit** capability is active (including **Background Delivery**) and provisioned without red errors.
5. Connect your iPhone to your Mac, select it as the run destination at the top, and hit **Cmd + R** to build and deploy!

## Data Privacy & Security Responsibility
⚠️ **IMPORTANT**: DataDonor is designed to give you complete ownership and control over your personal health data by extracting it from Apple's ecosystem and transmitting it to your own self-hosted server. 

Because this data contains highly sensitive personal, medical, and biometric information, **it is entirely your responsibility to secure your backend infrastructure.** Ensure that your server is properly firewalled, uses encryption at rest, and that your API keys and self-signed certificates are kept strictly confidential. The developers of DataDonor are not responsible for any data leaks, breaches, or mishandling of information once it leaves the iOS sandbox and is transmitted to your local server.

## License
MIT. See [LICENSE](LICENSE).
