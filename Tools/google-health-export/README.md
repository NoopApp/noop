# Google Health → NOOP bridge

Drive NOOP with a Google account (Fitbit / Pixel Watch data via the Google Health
API) instead of a WHOOP strap over BLE.

`export_google_health.py` fetches Google Health API data and writes it as an
**Apple Health `export.zip`**, which NOOP's existing `AppleHealthImporter` ingests
with no app changes. The recovery / strain / sleep / HRV analytics then run on the
imported data exactly as they would for a WHOOP or Apple Health import.

## Data type mapping

| Google Health data type | HealthKit identifier NOOP reads |
|---|---|
| `heart-rate` | `HeartRate` |
| `heart-rate-variability` (RMSSD) | `HeartRateVariabilitySDNN` (ms) |
| `daily-resting-heart-rate` | `RestingHeartRate` |
| `oxygen-saturation` | `OxygenSaturation` (emitted as a 0–1 fraction) |
| `daily-respiratory-rate` | `RespiratoryRate` |
| `steps` | `StepCount` |
| `weight` | `BodyMass` (kg) |
| `sleep` (stages) | `SleepAnalysis` (deep / core / REM / awake) |
| `exercise` | `<Workout>` |

## Usage

```bash
python3 export_google_health.py --days 14 --out export.zip
```

Then in NOOP (Strand, macOS): **File → Import → select `export.zip`**.

### Credentials

The tool needs a Google Cloud OAuth client (with the Google Health API enabled)
and a refresh token. It resolves them in this order:

1. CLI flags: `--client-id`, `--client-secret`, `--refresh-token`
2. Env vars: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN`
3. A local [fitbit-grafana](https://github.com/arpanghosh8453/fitbit-grafana)
   checkout (`--fitbit-grafana <path>`): reads `.env` and `tokens/fitbit.token`.

See that project's Google migration guide for obtaining a refresh token via the
Google Health migration parity tool.

## Verified

A 3-day export (17,015 records) imported through NOOP's `AppleHealthImporter`
produced 15,000 heart-rate samples, HRV/RHR/SpO₂/respiratory-rate series, 878
step records, 3 workouts, and 64 sleep-stage intervals (core 31, deep 14, REM 14,
awake 5). Standard library only; no dependencies.

## Roadmap

This is the bridge (phase 1). A native Swift `GoogleHealthImporter` in
`StrandImport` — OAuth + REST directly against `health.googleapis.com`, mapping to
the same normalized models — would remove the Python step and let the macOS/iOS
app connect a Google account in-app.
