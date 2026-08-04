---
title: HealthKit Data Gateway
name: datadonor-healthkit
description: Query Apple HealthKit data from DataDonor SQLite.
skill_type: data_source
author: tsella
version: 1.1.0
requires:
  - sqlite3
---

# HealthKit Data Gateway

## Overview

DataDonor is an iOS app that syncs Apple HealthKit data to a local Node.js + SQLite server. Data is collected automatically from Apple Watch + iPhone via anchored HealthKit queries.

## Database

Default path: `datadonor/server/data/datadonor.sqlite` (relative to project root or home directory).

### Tables

| Table | Purpose |
|---|---|
| `health_metrics` | Main time-series data |
| `devices` | iOS devices (single device per profile) |
| `checkpoints` | Sync anchors per data_type |
| `daily_sync_stats` | Aggregated daily record counts |

### `health_metrics` Columns

| Column | Type | Description |
|---|---|---|
| `id` | INTEGER PK | Row ID |
| `uuid` | TEXT | Apple Health unique identifier |
| `device_id` | TEXT | Links to `devices.device_id` |
| `data_type` | TEXT | HealthKit quantity/category type identifier |
| `start_date` | DATETIME | ISO 8601 UTC timestamp |
| `end_date` | DATETIME | ISO 8601 UTC timestamp |
| `value` | TEXT | Use `CAST(value AS REAL)` for numeric types |
| `unit` | TEXT | HealthKit unit (e.g., `count/min`, `kcal`, `degC`) |
| `source` | TEXT | Data source name (e.g., `Apple Watch`, `iPhone`) |
| `metadata` | JSON | Extra Apple Health metadata (JSON1) |
| `created_at` | DATETIME | Server ingest time |

**CRITICAL: ALL timestamps are UTC.** Convert to the user's local timezone for daily analysis.

## Data Types

### Cardiovascular & Vitals

| data_type | Description | Unit |
|---|---|---|
| `HKQuantityTypeIdentifierHeartRate` | Instantaneous HR | `count/min` |
| `HKQuantityTypeIdentifierRestingHeartRate` | Daily resting HR | `count/min` |
| `HKQuantityTypeIdentifierWalkingHeartRateAverage` | Walking HR avg | `count/min` |
| `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | HRV (SDNN) | `ms` |
| `HKQuantityTypeIdentifierHeartRateRecoveryOneMinute` | HR drop 60s post-workout | `count/min` |
| `HKQuantityTypeIdentifierVO2Max` | Cardio fitness | `mL/(kg·min)` |
| `HKQuantityTypeIdentifierOxygenSaturation` | SpO2 | `%` |
| `HKQuantityTypeIdentifierAtrialFibrillationBurden` | AFib burden estimate | `%` |
| `HKQuantityTypeIdentifierBloodPressureSystolic` | BP systolic | `mmHg` |
| `HKQuantityTypeIdentifierBloodPressureDiastolic` | BP diastolic | `mmHg` |
| `HKQuantityTypeIdentifierRespiratoryRate` | Breaths/min | `count/min` |
| `HKCategoryTypeIdentifierLowHeartRateEvent` | Low HR notifications | Category |

### Sleep & Environment

| data_type | Description |
|---|---|
| `HKCategoryTypeIdentifierSleepAnalysis` | Sleep stage: **0**=InBed, **1**=Asleep, **2**=Awake, **3**=Core, **4**=Deep, **5**=REM |
| `HKQuantityTypeIdentifierAppleSleepingWristTemperature` | Wrist temp during sleep |
| `HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances` | Breathing disturbance events |
| `HKQuantityTypeIdentifierEnvironmentalAudioExposure` | Ambient sound level |
| `HKQuantityTypeIdentifierHeadphoneAudioExposure` | Headphone audio level |
| `HKQuantityTypeIdentifierUVExposure` | UV Index exposure |
| `HKCategoryTypeIdentifierAudioExposureEvent` | Loud events |
| `HKQuantityTypeIdentifierTimeInDaylight` | Minutes daylight |

### Dive (Watch Ultra)

| data_type | Description | Unit |
|---|---|---|
| `HKQuantityTypeIdentifierUnderwaterDepth` | Depth during dive | `m` |
| `HKQuantityTypeIdentifierWaterTemperature` | Water temp during dive | `degC` |

### Activity & Exercise

| data_type | Description |
|---|---|
| `HKQuantityTypeIdentifierActiveEnergyBurned` | Active calories |
| `HKQuantityTypeIdentifierBasalEnergyBurned` | Resting calories |
| `HKQuantityTypeIdentifierStepCount` | Steps |
| `HKQuantityTypeIdentifierDistanceWalkingRunning` | Walk/run distance |
| `HKQuantityTypeIdentifierDistanceCycling` | Cycling distance |
| `HKQuantityTypeIdentifierDistanceSwimming` | Swimming distance |
| `HKQuantityTypeIdentifierDistanceDownhillSnowSports` | Ski/snowboard distance |
| `HKQuantityTypeIdentifierSwimmingStrokeCount` | Strokes |
| `HKQuantityTypeIdentifierFlightsClimbed` | Stairs |
| `HKQuantityTypeIdentifierAppleExerciseTime` | Exercise minutes |
| `HKQuantityTypeIdentifierAppleStandTime` | Stand minutes |
| `HKQuantityTypeIdentifierAppleMoveTime` | Move ring minutes |
| `HKCategoryTypeIdentifierAppleStandHour` | Stand hour events |
| `HKQuantityTypeIdentifierPhysicalEffort` | Workout effort score |
| `HKQuantityTypeIdentifierWorkoutEffortScore` | Apple Watch effort |
| `HKQuantityTypeIdentifierEstimatedWorkoutEffortScore` | Estimated effort |
| `HKQuantityTypeIdentifierWalkingAsymmetryPercentage` | Gait asymmetry |
| `HKQuantityTypeIdentifierWalkingStepLength` | Step length |
| `HKQuantityTypeIdentifierWalkingDoubleSupportPercentage` | Double support % |
| `HKQuantityTypeIdentifierWalkingSpeed` | Gait speed |
| `HKQuantityTypeIdentifierAppleWalkingSteadiness` | Fall risk |
| `HKQuantityTypeIdentifierNumberOfTimesFallen` | Fall events |

### Mobility (Watch 6+)

| data_type | Description |
|---|---|
| `HKQuantityTypeIdentifierWalkingSpeed` | m/s |
| `HKQuantityTypeIdentifierWalkingStepLength` | m |
| `HKQuantityTypeIdentifierWalkingDoubleSupportPercentage` | % |
| `HKQuantityTypeIdentifierWalkingAsymmetryPercentage` | % |

### Body Composition

| data_type | Description |
|---|---|
| `HKQuantityTypeIdentifierBodyMass` | kg |
| `HKQuantityTypeIdentifierBodyFatPercentage` | % |
| `HKQuantityTypeIdentifierLeanBodyMass` | kg |
| `HKQuantityTypeIdentifierBodyMassIndex` | BMI |
| `HKQuantityTypeIdentifierHeight` | m |
| `HKQuantityTypeIdentifierWaistCircumference` | m |
| `HKQuantityTypeIdentifierBodyTemperature` | degC |

### Vitals & Labs

| data_type | Description |
|---|---|
| `HKQuantityTypeIdentifierBloodGlucose` | mg/dL |
| `HKQuantityTypeIdentifierElectrocardiogram` | ECG waveform |
| `HKQuantityTypeIdentifierOxygenSaturation` | SpO2 |

### Nutrition

| data_type | Description | Unit |
|---|---|---|
| `HKQuantityTypeIdentifierDietaryEnergyConsumed` | Calories consumed | `kcal` |
| `HKQuantityTypeIdentifierDietaryWater` | Water intake | `mL` |

## Core Query Patterns

### Daily summary
```sql
-- Steps
SELECT date(start_date) AS day, SUM(CAST(value AS REAL)) AS steps
FROM health_metrics WHERE data_type = 'HKQuantityTypeIdentifierStepCount'
AND start_date >= date('now', '-7 days') GROUP BY day ORDER BY day;

-- Resting HR
SELECT date(start_date) AS day, CAST(value AS REAL) AS resting_hr
FROM health_metrics WHERE data_type = 'HKQuantityTypeIdentifierRestingHeartRate'
AND start_date >= date('now', '-7 days') ORDER BY day;

-- Active Energy
SELECT date(start_date) AS day, SUM(CAST(value AS REAL)) AS active_kcal
FROM health_metrics WHERE data_type = 'HKQuantityTypeIdentifierActiveEnergyBurned'
AND start_date >= date('now', '-7 days') GROUP BY day ORDER BY day;
```

### Sleep stages per night
```sql
SELECT 
  start_date, end_date,
  CASE CAST(value AS INTEGER)
    WHEN 0 THEN 'InBed'
    WHEN 1 THEN 'Asleep'
    WHEN 2 THEN 'Awake'
    WHEN 3 THEN 'Core'
    WHEN 4 THEN 'Deep'
    WHEN 5 THEN 'REM'
  END AS stage,
  (julianday(end_date) - julianday(start_date)) * 1440 AS minutes
FROM health_metrics
WHERE data_type = 'HKCategoryTypeIdentifierSleepAnalysis'
  AND start_date >= 'YYYY-MM-DDTHH:MM:SSZ'
  AND end_date   <= 'YYYY-MM-DDTHH:MM:SSZ'
ORDER BY start_date;
```

### Heart rate trend (hourly)
```sql
SELECT strftime('%Y-%m-%d %H:00:00', start_date) AS hour,
       AVG(CAST(value AS REAL)) AS avg_hr
FROM health_metrics
WHERE data_type = 'HKQuantityTypeIdentifierHeartRate'
  AND date(start_date) = 'YYYY-MM-DD'
GROUP BY hour ORDER BY hour;
```

### Dive session detection
```sql
SELECT 
  date(start_date) AS dive_day,
  MIN(CAST(value AS REAL)) AS max_depth_m,
  AVG(CAST(value AS REAL)) AS avg_depth_m,
  COUNT(*) AS sample_count,
  MIN(start_date) AS dive_start,
  MAX(end_date) AS dive_end
FROM health_metrics
WHERE data_type = 'HKQuantityTypeIdentifierUnderwaterDepth'
  AND CAST(value AS REAL) > 0
  AND start_date >= date('now', '-30 days')
GROUP BY strftime('%Y-%m-%d %H:%M', start_date, '-5 minutes')
ORDER BY dive_start DESC;
```

### Cross-reference with another data source
```sql
-- Join health_metrics with external events table (e.g., medication, travel, supplements)
-- Assumes external database has: events(date, event_type, description)
SELECT 
  h.date, 
  h.resting_hr, 
  e.event_type
FROM (
  SELECT date(start_date) AS date, CAST(value AS REAL) AS resting_hr
  FROM health_metrics
  WHERE data_type = 'HKQuantityTypeIdentifierRestingHeartRate'
    AND date(start_date) >= 'YYYY-MM-DD'
) h
LEFT JOIN events e ON h.date = e.date
ORDER BY h.date;
```

## Python Integration

Use the `execute_code` tool for one-off analysis scripts with matplotlib/pandas, or load the `jupyter-live-kernel` skill for interactive exploratory work.

## Pitfalls

1. **ALL timestamps are UTC.** Convert to local time for daily analysis.
2. **`value` is TEXT.** Always `CAST(value AS REAL)` for numeric metrics. For sleep: `CAST(value AS INTEGER)`.
3. **Heart rate is high-frequency.** Add `start_date >= bound` to every query.
4. **Sleep records span intervals.** Apple Watch chunks are 1–5 min. Use `start_date`/`end_date` ranges.
5. **Sparse manual data.** Blood pressure, height, body temperature, blood glucose are likely manually entered. Treat accordingly.
6. **WAL mode active.** Safe to run reads while server writes. Do not lock the DB with long transactions.
7. **Server running.** The DataDonor server runs via PM2. Do not stop it.
8. **Dive data is sparse.** Requires Watch Ultra + Depth app use. Check `COUNT(*) > 0` before assuming presence.
9. **Sleep breathing disturbances** require Watch Series 9 or Ultra 2 + iOS 17+. Only appears if apnea notifications enabled.
10. **AFib burden** requires Watch with irregular rhythm notification + diagnosis.
11. **Unit mismatch bug history:** `timeInDaylight` (fixed 2025), `physicalEffort` (fixed 2025). New data types added to `unit(for:)` must specify the correct `HKUnit`. The default `.count()` fallback silently produces `0.0` for incompatible units. Warn-on-mismatch logging added to `mapSample()` catches future issues.
