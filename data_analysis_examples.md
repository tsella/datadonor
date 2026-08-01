# Data Analysis Examples

Since DataDonor stores all collected Apple Health data into a local SQLite database (`server/data/datadonor.sqlite`), you have full freedom to extract, analyze, and visualize your health metrics using whatever data science tools you prefer.

Below is a complete Python example that demonstrates how to:
1. Connect to the SQLite database.
2. Extract **Heart Rate**, **Sleep Analysis**, and **Exercise Time** data.
3. Automatically convert UTC timestamps to your local timezone.
4. Plot a beautiful overlaid graph using `pandas` and `matplotlib`.

## Requirements

Ensure you have Python installed, and install the required data science packages:

```bash
pip install pandas matplotlib pytz
```

## Example: Plotting Daily Heart Rate with Sleep & Exercise Overlays

Create a script named `plot_metrics.py` and run it from the root of your server directory (or modify the `db_path` variable to point to your `datadonor.sqlite` file).

```python
import sqlite3
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import pytz
from datetime import timedelta

# 1. Connect to the DataDonor SQLite Database
db_path = "server/data/datadonor.sqlite"
conn = sqlite3.connect(db_path)

# Set your local timezone
local_tz = pytz.timezone('America/New_York')

# 2. Fetch Heart Rate Data
query_hr = """
SELECT start_date, CAST(value AS REAL) as hr 
FROM health_metrics 
WHERE data_type = 'HKQuantityTypeIdentifierHeartRate'
"""
df_hr = pd.read_sql_query(query_hr, conn)
# Convert UTC strings to aware datetime objects, then to local time
df_hr['start_date'] = pd.to_datetime(df_hr['start_date']).dt.tz_convert(local_tz)

# 3. Fetch Sleep Data
query_sleep = """
SELECT start_date, end_date, value 
FROM health_metrics 
WHERE data_type = 'HKCategoryTypeIdentifierSleepAnalysis'
"""
df_sleep = pd.read_sql_query(query_sleep, conn)
if not df_sleep.empty:
    df_sleep['start_date'] = pd.to_datetime(df_sleep['start_date']).dt.tz_convert(local_tz)
    df_sleep['end_date'] = pd.to_datetime(df_sleep['end_date']).dt.tz_convert(local_tz)

# 4. Fetch Exercise Data
query_exercise = """
SELECT start_date, end_date 
FROM health_metrics 
WHERE data_type = 'HKQuantityTypeIdentifierAppleExerciseTime'
"""
df_exercise = pd.read_sql_query(query_exercise, conn)
if not df_exercise.empty:
    df_exercise['start_date'] = pd.to_datetime(df_exercise['start_date']).dt.tz_convert(local_tz)
    df_exercise['end_date'] = pd.to_datetime(df_exercise['end_date']).dt.tz_convert(local_tz)

conn.close()

# --- Plotting ---

# Define the target day (e.g., Today)
target_date = pd.Timestamp.now(tz=local_tz).date()

# Filter Heart Rate for the target date
df_hr_day = df_hr[df_hr['start_date'].dt.date == target_date].sort_values('start_date')

if df_hr_day.empty:
    print(f"No heart rate data found for {target_date}")
    exit()

plt.figure(figsize=(12, 6))

# Plot Heart Rate as a line graph
plt.plot(df_hr_day['start_date'], df_hr_day['hr'], color='#FF6B6B', marker='o', linestyle='-', markersize=3, linewidth=1.5, zorder=3, label="Heart Rate")

added_labels = set()
day_start = pd.Timestamp(target_date, tz=local_tz)
day_end = day_start + timedelta(days=1)

# Mapping Apple Health Sleep Values to Colors
sleep_colors = {
    '0': ('#E9ECEF', 'In Bed'),
    '1': ('#A3CEF1', 'Asleep (Unspecified)'),
    '3': ('#6096BA', 'Core Sleep'),
    '4': ('#274C77', 'Deep Sleep'),
    '5': ('#8B80F9', 'REM Sleep')
}

# Shade Sleep Periods
if not df_sleep.empty:
    df_sleep_day = df_sleep[(df_sleep['end_date'] > day_start) & (df_sleep['start_date'] < day_end)]
    for _, row in df_sleep_day.iterrows():
        val = str(row['value'])
        if val == '2': continue # Ignore "Awake" periods
        
        color, label = sleep_colors.get(val, ('#cccccc', 'Unknown Sleep'))
        
        s_time = max(row['start_date'], day_start)
        e_time = min(row['end_date'], day_end)
        
        plt.axvspan(s_time, e_time, color=color, alpha=0.5, zorder=1, label=label if label not in added_labels else "")
        added_labels.add(label)

# Shade Exercise Periods
if not df_exercise.empty:
    df_ex_day = df_exercise[(df_exercise['end_date'] > day_start) & (df_exercise['start_date'] < day_end)]
    for _, row in df_ex_day.iterrows():
        s_time = max(row['start_date'], day_start)
        e_time = min(row['end_date'], day_end)
        
        label = "Exercise"
        plt.axvspan(s_time, e_time, color='#70E000', alpha=0.4, zorder=2, label=label if label not in added_labels else "")
        added_labels.add(label)

# Formatting
plt.title(f'Heart Rate, Sleep & Exercise Analysis - {target_date}', fontsize=16, fontweight='bold', color='#333333')
plt.xlabel('Time', fontsize=12)
plt.ylabel('Heart Rate (bpm)', fontsize=12)
plt.grid(True, linestyle='--', alpha=0.4, zorder=2)
plt.gca().set_facecolor('#F8F9FA')

# Format X-Axis Time
plt.gca().xaxis.set_major_formatter(mdates.DateFormatter('%H:%M', tz=local_tz))
plt.xticks(rotation=45)

# Add Legend outside the plot
handles, labels = plt.gca().get_legend_handles_labels()
if handles:
    plt.legend(handles, labels, loc='upper right', bbox_to_anchor=(1.15, 1))
    
plt.tight_layout()
plt.savefig("daily_metrics_overlay.png", dpi=200, bbox_inches='tight')
print("Plot successfully saved to daily_metrics_overlay.png")
```

When you run this script, it will generate a high-resolution image (`daily_metrics_overlay.png`) featuring your daily heart rate trend plotted over visually distinct background shades representing your sleep stages and workout sessions.
