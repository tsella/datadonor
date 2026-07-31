# DataDonor: Server Implementation Specification

This document provides the technical requirements for building the backend server (on your Linux machine) that will receive Apple Health data from the DataDonor iOS application.

## 1. Network Discovery (mDNS / Bonjour)

To allow the iOS app to seamlessly discover the server on the local Wi-Fi network without manual IP configuration, your server MUST broadcast an mDNS service.

* **Service Type**: `_datadonor._tcp`
* **Transport**: TCP
* **Port**: The port your web server is running on (e.g., `443`, `8443`)

*Tip: On Linux, this can be easily achieved using Avahi (`avahi-publish-service`) or an mDNS library in your preferred language (e.g., `zeroconf` in Python, `bonjour` in Node).*

## 2. Security & Authentication

* **TLS/HTTPS**: The server MUST serve traffic over HTTPS. Self-signed or locally signed certificates are permitted; the iOS app is configured to trust the certificate provided by the discovered mDNS host.
* **Authentication**: All endpoints require a Shared Secret / API Key provided via the `Authorization` header.
  * Format: `Authorization: Bearer <your_shared_secret>`

## 3. REST API Endpoints

The server must implement the following three endpoints:

### A. Livelihood & Validation (`/api/v1/ping`)
Used by the app during initial setup to validate the API key, and immediately prior to any data sync to ensure the server is online and reachable.

* **Method**: `GET`
* **Path**: `/api/v1/ping`
* **Headers**:
  * `Authorization: Bearer <your_shared_secret>`
* **Expected Response**:
  * Status: `200 OK`
  * Body: Optional (e.g., `{"status": "ok"}`)

---

### B. Checkpoint Inquiry (`/api/v1/health-sync/checkpoint`)
Before pushing a payload, the app queries this endpoint to determine the last successfully synced anchor for each data type. This guarantees the app won't send duplicate data if its local state is ever cleared.

* **Method**: `GET`
* **Path**: `/api/v1/health-sync/checkpoint`
* **Headers**:
  * `Authorization: Bearer <your_shared_secret>`
  * `X-Device-ID`: `<UUID of the iOS Device>` *(Use this to namespace checkpoints per device)*
* **Expected Response**:
  * Status: `200 OK`
  * Content-Type: `application/json`
  * Body (JSON):
    ```json
    {
      "checkpoints": {
        "HeartRate": "HKQueryAnchor_encoded_string",
        "StepCount": "HKQueryAnchor_encoded_string",
        "SleepAnalysis": "HKQueryAnchor_encoded_string"
      }
    }
    ```
*(Note: If the server returns an empty object `{}`, or if a specific HealthKit data type is omitted from the response, the iOS app will assume it needs to perform a full historical sync for that type).*

---

### C. Data Ingestion (`/api/v1/health-sync`)
Receives batches of HealthKit data.

* **Method**: `POST`
* **Path**: `/api/v1/health-sync`
* **Headers**:
  * `Authorization: Bearer <your_shared_secret>`
  * `X-Device-ID`: `<UUID of the iOS Device>`
  * `Content-Type`: `application/json`
* **Request Body** (JSON):
  ```json
  {
    "device_id": "D9B91278-BA82-4FE8-9E11-23F1A7A78C90",
    "sync_timestamp": "2026-07-31T18:11:33Z",
    "data": [
      {
        "type": "HeartRate",
        "value": 72.0,
        "unit": "count/min",
        "start_date": "2026-07-31T18:00:00Z",
        "end_date": "2026-07-31T18:00:00Z",
        "source": "Apple Watch"
      },
      {
        "type": "SleepAnalysis",
        "value": "InBed",
        "unit": "category",
        "start_date": "2026-07-31T22:00:00Z",
        "end_date": "2026-08-01T06:00:00Z",
        "source": "iPhone"
      }
    ]
  }
  ```
* **Expected Response**:
  * Status: `200 OK` or `201 Created`
  * *Important*: The app relies on a 2xx success code to know it is safe to update its local anchors. If the server fails to persist the data, it MUST return a 4xx or 5xx code so the app retains the anchor and retries on the next sync opportunity.

## 4. Data Storage Recommendations

Apple Health data is essentially **time-series data** with highly variable payloads depending on the data type (e.g., Heart Rate is a simple number, while Sleep Analysis is a category string). 

### Recommended Database: SQLite

For a local Linux server, **SQLite** is highly recommended. It is zero-configuration, extremely fast for local writes, requires no background daemon, and is easy to back up (it's just a single file). 

Because HealthKit data types vary in structure, the best approach in SQLite is a **hybrid schema** utilizing SQLite's built-in `JSON` capabilities. This gives you the speed of a relational database with the flexibility of NoSQL.

#### Proposed SQLite Schema

**Table 1: `devices`** (Tracks the iOS devices)
```sql
CREATE TABLE devices (
    device_id TEXT PRIMARY KEY,
    name TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

**Table 2: `checkpoints`** (Stores the latest anchor per device and data type for the Checkpoint Endpoint)
```sql
CREATE TABLE checkpoints (
    device_id TEXT,
    data_type TEXT,
    anchor TEXT NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (device_id, data_type),
    FOREIGN KEY (device_id) REFERENCES devices(device_id)
);
```

**Table 3: `health_metrics`** (The time-series data table)
```sql
CREATE TABLE health_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT,
    data_type TEXT NOT NULL,
    start_date DATETIME NOT NULL,
    end_date DATETIME NOT NULL,
    value TEXT NOT NULL,          -- Stored as TEXT to gracefully handle both numbers (72.0) and categories ("InBed")
    unit TEXT,
    source TEXT,
    metadata JSON,                -- NoSQL flexibility for extra Apple Health metadata (JSON1 extension)
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (device_id) REFERENCES devices(device_id)
);

-- Essential index for fast time-series querying and dashboarding
CREATE INDEX idx_metrics_type_date ON health_metrics(data_type, start_date);
```

### Alternative: NoSQL (MongoDB or TinyDB)

If you prefer a pure NoSQL approach, **MongoDB** (or **TinyDB** if you are writing the server in Python and want a lightweight file-based approach) is a fantastic alternative. You can simply dump the incoming JSON payloads directly into collections without worrying about strict migrations.

**Recommended NoSQL Structure:**
* **Collection**: `metrics`
* **Document Structure**: When the `POST /api/v1/health-sync` payload arrives, extract the items from the `data` array, append the `device_id` and `sync_timestamp` to each item, and insert them as separate documents.
* **Indexes**: Create compound indexes on `{ "device_id": 1, "type": 1, "start_date": -1 }` for fast retrieval and time-series graphing.
