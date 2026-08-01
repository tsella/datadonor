# DataDonor

DataDonor is an iOS application designed to run in the background, collect all available Apple Health data via HealthKit, and securely transmit it to a local server. The app features mDNS server discovery, strict Wi-Fi SSID network monitoring, and automatic background syncs to ensure your health data remains securely stored on your own local infrastructure.

## Supported Health Data
DataDonor comprehensively extracts both time-series quantity samples and category events. Currently supported metrics include:
- **Cardiovascular & Vitals**: Heart Rate, Resting Heart Rate, Walking Heart Rate Average, Heart Rate Variability (HRV), VO2 Max, Oxygen Saturation (SpO2), Blood Pressure (Systolic/Diastolic), Body Mass, Height, BMI, Body Fat Percentage, Lean Body Mass.
- **Activity & Mobility**: Step Count, Distance (Walking/Running, Cycling, Swimming), Swimming Stroke Count, Flights Climbed, Active/Basal Energy Burned, Exercise Time, Stand Time, Walking Asymmetry, Step Length, Double Support Time, Walking Speed.
- **Sleep & Environment**: Sleep Stages (Analysis), Respiratory Rate, Wrist Temperature, Environmental Audio Exposure, Time in Daylight.
- **Events & Characteristics**: Mindful Sessions, Menstrual Flow, Irregular Rhythm Notifications, High/Low Heart Rate Events.

*(Note: Static characteristic data like Date of Birth and Biological Sex require separate extraction pathways and can be added on request.)*

## Features
- **HealthKit Integration**: Broad-net extraction engine that securely reads and correctly standardizes units for over 35 distinct HealthKit metrics.
- **Background URLSession**: Ensures that massive historical data payloads successfully upload even if the app is placed in the background.
- **Network Path Monitoring**: Restricts data syncing to a specific Wi-Fi SSID to ensure data only transfers when connected to your secure local network.
- **Self-Signed Certificate Trust**: Allows the use of locally signed certificates for your server backend.

## API Key Configuration & QR Scanner
To securely link your iOS client to your backend server, DataDonor uses an API Key. Instead of manually typing long alphanumeric strings on your iPhone, you can quickly scan a QR code!

1. Open your terminal and navigate to the `server/` directory.
2. Run `npm run qr` (or `node generate-qr.js`).
3. Your server will read the `API_KEY` you defined in `server/config.json` and print a large QR code directly in your terminal.
4. On the iOS DataDonor app, tap the QR code icon next to the API Key text field and point your camera at the terminal screen to instantly configure it!

## Server Specification
This app requires a backend server to receive the data. See the `server_specification.md` document for the full JSON payload specifications, checkpoint syncing mechanics, and endpoint requirements.

## Data Analysis Examples
Want to visualize the data once it hits the database? We've provided a complete Python guide on extracting, formatting, and plotting your health metrics (like Heart Rate overlaid with Sleep and Exercise times) in the [`data_analysis_examples.md`](data_analysis_examples.md) document.

## Deployment to Personal Device
To run DataDonor on your personal iPhone, you must build and deploy it directly from Xcode. Please note that Apple requires an Apple Developer account to deploy custom apps that utilize HealthKit entitlements to a physical device.

1. Register for an [Apple Developer Account](https://developer.apple.com/) (a free tier account is sufficient, though the app will expire every 7 days and require a rebuild. A paid account allows 1-year provisioning).
2. Open `client/DataDonor.xcodeproj` in Xcode.
3. In the project navigator, select the `DataDonor` target, navigate to the **Signing & Capabilities** tab, and select your Personal Team from the dropdown.
4. Ensure the **HealthKit** and **Access WiFi Information** capabilities are active and provisioned without red errors.
5. Connect your iPhone to your Mac, select it as the run destination at the top, and hit **Cmd + R** to build and deploy!

## Data Privacy & Security Responsibility
⚠️ **IMPORTANT**: DataDonor is designed to give you complete ownership and control over your personal health data by extracting it from Apple's ecosystem and transmitting it to your own self-hosted server. 

Because this data contains highly sensitive personal, medical, and biometric information, **it is entirely your responsibility to secure your backend infrastructure.** Ensure that your server is properly firewalled, uses encryption at rest, and that your API keys and self-signed certificates are kept strictly confidential. The developers of DataDonor are not responsible for any data leaks, breaches, or mishandling of information once it leaves the iOS sandbox and is transmitted to your local server.

## Author
Tom Sella (<tsella@gmail.com>)

## Repository
[https://github.com/tsella/datadonor](https://github.com/tsella/datadonor)

## License
MIT License

Copyright (c) 2026 Tom Sella

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
