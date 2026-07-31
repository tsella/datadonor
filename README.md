<div align="center">
  <img src="/Users/tsella/.gemini/antigravity/brain/d5896aac-9ddd-44a6-b8ea-284b465c1acd/datadonor_app_icon_transparent_1785537226058.jpg" alt="DataDonor Logo" width="200" />
</div>

# DataDonor

DataDonor is an iOS application designed to run in the background, collect all available Apple Health data via HealthKit, and securely transmit it to a local Linux server. The app features mDNS server discovery, strict Wi-Fi SSID network monitoring, and automatic background syncs to ensure your health data remains securely stored on your own local infrastructure.

## Features
- **HealthKit Integration**: Requests authorization and collects time-series data across all available HealthKit identifiers.
- **mDNS Server Discovery**: Automatically finds your local backend server via Bonjour (`_datadonor._tcp`) without manual IP configuration.
- **Background URLSession**: Ensures that massive historical data payloads successfully upload even if the app is placed in the background.
- **Network Path Monitoring**: Restricts data syncing to a specific Wi-Fi SSID to ensure data only transfers when connected to your secure local network.
- **Self-Signed Certificate Trust**: Allows the use of locally signed certificates for your Linux server backend.

## Server Specification
This app requires a backend server to receive the data. See the `server_specification.md` document for the full JSON payload specifications, checkpoint syncing mechanics, and endpoint requirements.

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
