<div align="center">
  <img src="/Users/tsella/.gemini/antigravity/brain/d5896aac-9ddd-44a6-b8ea-284b465c1acd/datadonor_app_icon_transparent.png" alt="DataDonor Logo" width="200" />
</div>

# DataDonor

DataDonor is an iOS application designed to run in the background, collect all available Apple Health data via HealthKit, and securely transmit it to a local Linux server. The app features mDNS server discovery, strict Wi-Fi SSID network monitoring, and automatic background syncs to ensure your health data remains securely stored on your own local infrastructure.

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
- **Self-Signed Certificate Trust**: Allows the use of locally signed certificates for your Linux server backend.

## Server Specification
This app requires a backend server to receive the data. See the `server_specification.md` document for the full JSON payload specifications, checkpoint syncing mechanics, and endpoint requirements.

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
