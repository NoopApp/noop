#!/usr/bin/env python3
"""Export Google Health API data as an Apple Health `export.zip`.

NOOP's `AppleHealthImporter` already ingests Apple Health exports (heart rate,
HRV, resting HR, SpO2, respiratory rate, sleep stages, workouts) into the same
normalized model the recovery / strain / sleep analytics read. This tool fetches
the equivalent Google Health API data types and writes them in that exact format,
so a Google / Fitbit account can drive NOOP with no app changes.

It maps Google Health data types to the HealthKit identifiers NOOP recognizes:

    heart-rate                    -> HKQuantityTypeIdentifierHeartRate
    heart-rate-variability        -> HKQuantityTypeIdentifierHeartRateVariabilitySDNN (RMSSD, ms)
    daily-resting-heart-rate      -> HKQuantityTypeIdentifierRestingHeartRate
    oxygen-saturation             -> HKQuantityTypeIdentifierOxygenSaturation (0-1 fraction)
    daily-respiratory-rate        -> HKQuantityTypeIdentifierRespiratoryRate
    steps                         -> HKQuantityTypeIdentifierStepCount
    weight                        -> HKQuantityTypeIdentifierBodyMass (kg)
    sleep (stages)                -> HKCategoryTypeIdentifierSleepAnalysis
    exercise                      -> <Workout>

Credentials are read (in order) from CLI flags, environment variables, or the
local fitbit-grafana setup (`~/code/fitbit-grafana/.env` + `tokens/fitbit.token`).
Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from xml.sax.saxutils import quoteattr

TOKEN_URL = "https://oauth2.googleapis.com/token"
HEALTH_BASE = "https://health.googleapis.com/v4/users/me/dataTypes"
DEFAULT_FITBIT_GRAFANA = Path.home() / "code" / "fitbit-grafana"

# Google sleep stage -> HealthKit SleepAnalysis category value.
SLEEP_STAGE_TO_HK = {
    "DEEP": "HKCategoryValueSleepAnalysisAsleepDeep",
    "LIGHT": "HKCategoryValueSleepAnalysisAsleepCore",
    "REM": "HKCategoryValueSleepAnalysisAsleepREM",
    "AWAKE": "HKCategoryValueSleepAnalysisAwake",
    "ASLEEP": "HKCategoryValueSleepAnalysisAsleepUnspecified",
    "RESTLESS": "HKCategoryValueSleepAnalysisAwake",
}


# --------------------------------------------------------------------------- #
# Credentials
# --------------------------------------------------------------------------- #
def _parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip().strip('"').strip("'")
    return out


def load_credentials(args: argparse.Namespace) -> tuple[str, str, str]:
    env_file = _parse_env_file(Path(args.fitbit_grafana) / ".env")
    client_id = args.client_id or os.environ.get("GOOGLE_CLIENT_ID") or env_file.get("GOOGLE_CLIENT_ID")
    client_secret = (
        args.client_secret or os.environ.get("GOOGLE_CLIENT_SECRET") or env_file.get("GOOGLE_CLIENT_SECRET")
    )
    refresh_token = args.refresh_token or os.environ.get("GOOGLE_REFRESH_TOKEN")
    if not refresh_token:
        token_file = Path(args.fitbit_grafana) / "tokens" / "fitbit.token"
        if token_file.exists():
            refresh_token = json.loads(token_file.read_text()).get("refresh_token")
    missing = [
        name
        for name, val in [
            ("client id", client_id),
            ("client secret", client_secret),
            ("refresh token", refresh_token),
        ]
        if not val
    ]
    if missing:
        sys.exit(
            f"Missing credentials: {', '.join(missing)}. Provide via flags, "
            f"GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET/GOOGLE_REFRESH_TOKEN env vars, "
            f"or a fitbit-grafana checkout (--fitbit-grafana)."
        )
    return client_id, client_secret, refresh_token


def get_access_token(client_id: str, client_secret: str, refresh_token: str) -> str:
    data = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        }
    ).encode()
    with urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=data)) as resp:
        return json.load(resp)["access_token"]


# --------------------------------------------------------------------------- #
# Google Health fetch
# --------------------------------------------------------------------------- #
def _http_get(url: str, token: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def fetch_day(data_type: str, day: datetime, token: str) -> list[dict]:
    """Fetch one local day of a data type, mirroring the proven filter logic:
    try server-side filters, fall back to an unfiltered page filtered by date."""
    start_iso = day.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    end_iso = (day + timedelta(days=1)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    date_str = day.strftime("%Y-%m-%d")
    next_str = (day + timedelta(days=1)).strftime("%Y-%m-%d")
    member = data_type.replace("-", "_")

    if data_type in ("heart-rate", "oxygen-saturation", "weight", "heart-rate-variability"):
        filters = [f'{member}.sample_time.physical_time >= "{start_iso}" AND {member}.sample_time.physical_time < "{end_iso}"']
    elif data_type == "steps":
        filters = [f'{member}.interval.start_time >= "{start_iso}" AND {member}.interval.start_time < "{end_iso}"']
    elif data_type in ("sleep", "exercise"):
        filters = [
            f'{member}.interval.civil_start_time >= "{date_str}T00:00:00" AND {member}.interval.civil_start_time < "{next_str}T00:00:00"',
            f'{member}.interval.civil_end_time >= "{date_str}T00:00:00" AND {member}.interval.civil_end_time < "{next_str}T00:00:00"',
        ]
    else:
        filters = []

    for filt in filters:
        url = f"{HEALTH_BASE}/{data_type}/dataPoints?pageSize=100000&filter=" + urllib.parse.quote(filt)
        try:
            return _http_get(url, token).get("dataPoints", [])
        except urllib.error.HTTPError:
            continue

    # Unfiltered fallback (daily aggregates): keep points whose civil date matches.
    url = f"{HEALTH_BASE}/{data_type}/dataPoints?pageSize=100000"
    points = _http_get(url, token).get("dataPoints", [])
    return [p for p in points if _point_date(p, data_type) == date_str]


def _point_date(point: dict, data_type: str) -> str | None:
    payload = point.get(_camel(data_type), {})
    date = payload.get("date")
    if isinstance(date, dict):
        return f"{date['year']:04d}-{date['month']:02d}-{date['day']:02d}"
    # Interval-based types (sleep, exercise): use the civil start date.
    civil = payload.get("interval", {}).get("civilStartTime", {})
    if isinstance(civil, dict) and isinstance(civil.get("date"), dict):
        d = civil["date"]
        return f"{d['year']:04d}-{d['month']:02d}-{d['day']:02d}"
    return None


def _camel(data_type: str) -> str:
    parts = data_type.split("-")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


# --------------------------------------------------------------------------- #
# Time helpers
# --------------------------------------------------------------------------- #
_RFC3339 = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})[T ](?P<time>\d{2}:\d{2}:\d{2})"
    r"(?:\.(?P<frac>\d+))?(?P<tz>Z|[+-]\d{2}:?\d{2})?$"
)


def _parse_utc(iso: str) -> datetime:
    """Parse an RFC-3339 timestamp to an aware datetime, robustly on Python 3.9+.

    Google Health emits up to 9-digit (nanosecond) fractional seconds and a trailing "Z".
    `datetime.fromisoformat` rejects BOTH before Python 3.11 (the floor we support), so we
    normalise by hand: truncate the fraction to microseconds and convert "Z"/±HHMM to a
    fromisoformat-friendly ±HH:MM offset. Without this, any real sub-second sample (i.e. most
    heart-rate data) raises ValueError and aborts the whole export.
    """
    m = _RFC3339.match(iso.strip())
    if not m:
        # Genuinely malformed — let fromisoformat raise rather than silently mis-parse.
        return datetime.fromisoformat(iso.strip().replace("Z", "+00:00"))
    micros = (m.group("frac") or "")[:6].ljust(6, "0")
    tz = m.group("tz") or "Z"
    if tz == "Z":
        off = "+00:00"
    elif ":" in tz:
        off = tz
    else:  # ±HHMM -> ±HH:MM
        off = tz[:3] + ":" + tz[3:]
    return datetime.fromisoformat(f"{m.group('date')}T{m.group('time')}.{micros}{off}")


def _offset_seconds(value: str | None) -> int:
    if isinstance(value, str) and value.endswith("s"):
        try:
            return int(value[:-1])
        except ValueError:
            return 0
    return 0


def _duration_seconds(value) -> int | None:
    """Seconds from a protobuf Duration. Google encodes these as e.g. "1800.000s" / "3.5s" /
    "3600s" — `_offset_seconds` only handles the whole-second form (its `int(value[:-1])` throws
    on the fractional encoding), which silently dropped every fractional-duration workout. Here we
    parse via float() so "1800.000s" -> 1800. Returns None when there's nothing usable (the caller
    then omits the attribute and the importer falls back to endDate-startDate)."""
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str) and value.endswith("s"):
        try:
            return int(round(float(value[:-1])))
        except ValueError:
            return None
    return _first_numeric(value)


def ah_datetime(utc_iso: str, offset_seconds: int) -> str:
    """Format a UTC ISO timestamp as Apple Health local time: `YYYY-MM-DD HH:MM:SS ±HHMM`."""
    tz = timezone(timedelta(seconds=offset_seconds))
    local = _parse_utc(utc_iso).astimezone(tz)
    sign = "+" if offset_seconds >= 0 else "-"
    mins = abs(offset_seconds) // 60
    return f"{local.strftime('%Y-%m-%d %H:%M:%S')} {sign}{mins // 60:02d}{mins % 60:02d}"


def ah_date_at(date_str: str, hour: int = 4) -> str:
    """A representative local timestamp for a daily metric (defaults to 04:00, mid-sleep)."""
    return f"{date_str} {hour:02d}:00:00 +0000"


# --------------------------------------------------------------------------- #
# Record builders -> list of XML strings
# --------------------------------------------------------------------------- #
def _record(rec_type: str, value: str, start: str, end: str, unit: str | None) -> str:
    attrs = (
        f'type={quoteattr(rec_type)} sourceName="Google Health" '
        f'startDate={quoteattr(start)} endDate={quoteattr(end)} value={quoteattr(value)}'
    )
    if unit:
        attrs += f" unit={quoteattr(unit)}"
    return f" <Record {attrs}/>"


def _first_numeric(value):
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    if isinstance(value, dict):
        for nested in value.values():
            got = _first_numeric(nested)
            if got is not None:
                return got
    return None


def build_records(data_type: str, points: list[dict], counts: dict[str, int]) -> list[str]:
    out: list[str] = []
    for p in points:
        payload = p.get(_camel(data_type), {})
        if data_type == "heart-rate":
            v = _first_numeric(payload.get("beatsPerMinute"))
            ts = _sample_ts(payload)
            if v is not None and ts:
                out.append(_record("HKQuantityTypeIdentifierHeartRate", str(v), ts, ts, "count/min"))
        elif data_type == "heart-rate-variability":
            v = _first_numeric(payload.get("rootMeanSquareOfSuccessiveDifferencesMilliseconds"))
            ts = _sample_ts(payload)
            if v is not None and ts:
                out.append(_record("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", str(v), ts, ts, "ms"))
        elif data_type == "daily-resting-heart-rate":
            v = _first_numeric(payload.get("beatsPerMinute"))
            d = _point_date(p, data_type)
            if v is not None and d:
                t = ah_date_at(d)
                out.append(_record("HKQuantityTypeIdentifierRestingHeartRate", str(v), t, t, "count/min"))
        elif data_type == "oxygen-saturation":
            v = _first_numeric(payload.get("percentage"))
            ts = _sample_ts(payload)
            if v is not None and ts:  # importer multiplies by 100 -> emit as fraction
                out.append(_record("HKQuantityTypeIdentifierOxygenSaturation", str(v / 100.0), ts, ts, "%"))
        elif data_type == "daily-respiratory-rate":
            v = _first_numeric(payload.get("breathsPerMinute"))
            d = _point_date(p, data_type)
            if v is not None and d:
                t = ah_date_at(d)
                out.append(_record("HKQuantityTypeIdentifierRespiratoryRate", str(v), t, t, "count/min"))
        elif data_type == "steps":
            v = _first_numeric(payload.get("count"))
            start, end = _interval_ts(payload)
            if v is not None and start:
                out.append(_record("HKQuantityTypeIdentifierStepCount", str(int(v)), start, end or start, "count"))
        elif data_type == "weight":
            grams = _first_numeric(payload.get("weightGrams"))
            ts = _sample_ts(payload)
            if grams is not None and ts:
                out.append(_record("HKQuantityTypeIdentifierBodyMass", str(grams / 1000.0), ts, ts, "kg"))
        elif data_type == "sleep":
            out.extend(_sleep_records(payload))
        elif data_type == "exercise":
            wk = _workout_record(payload)
            if wk:
                out.append(wk)
        counts[data_type] = counts.get(data_type, 0) + 1
    return out


def _sample_ts(payload: dict) -> str | None:
    st = payload.get("sampleTime")
    if isinstance(st, dict) and st.get("physicalTime"):
        return ah_datetime(st["physicalTime"], _offset_seconds(st.get("utcOffset")))
    return None


def _interval_ts(payload: dict) -> tuple[str | None, str | None]:
    iv = payload.get("interval", {})
    if not iv.get("startTime"):
        return None, None
    off = _offset_seconds(iv.get("startUtcOffset"))
    start = ah_datetime(iv["startTime"], off)
    end = ah_datetime(iv["endTime"], _offset_seconds(iv.get("endUtcOffset"))) if iv.get("endTime") else None
    return start, end


def _sleep_records(payload: dict) -> list[str]:
    out: list[str] = []
    # An explicit "InBed" record spanning the whole session, so sleep efficiency
    # (asleep / in-bed) can be computed downstream — Apple Health records this
    # separately from the per-stage intervals.
    iv = payload.get("interval", {})
    if iv.get("startTime") and iv.get("endTime"):
        start = ah_datetime(iv["startTime"], _offset_seconds(iv.get("startUtcOffset")))
        end = ah_datetime(iv["endTime"], _offset_seconds(iv.get("endUtcOffset")))
        out.append(_record("HKCategoryTypeIdentifierSleepAnalysis", "HKCategoryValueSleepAnalysisInBed", start, end, None))
    for stage in payload.get("stages", []) or []:
        if not stage.get("startTime") or not stage.get("endTime"):
            continue
        hk = SLEEP_STAGE_TO_HK.get((stage.get("type") or "").upper())
        if not hk:
            continue
        start = ah_datetime(stage["startTime"], _offset_seconds(stage.get("startUtcOffset")))
        end = ah_datetime(stage["endTime"], _offset_seconds(stage.get("endUtcOffset")))
        out.append(_record("HKCategoryTypeIdentifierSleepAnalysis", hk, start, end, None))
    return out


def _workout_record(payload: dict) -> str | None:
    iv = payload.get("interval", {})
    if not iv.get("startTime") or not iv.get("endTime"):
        return None
    start = ah_datetime(iv["startTime"], _offset_seconds(iv.get("startUtcOffset")))
    end = ah_datetime(iv["endTime"], _offset_seconds(iv.get("endUtcOffset")))
    name = payload.get("displayName") or payload.get("exerciseType") or "Unknown"
    metrics = payload.get("metricsSummary", {}) if isinstance(payload.get("metricsSummary"), dict) else {}
    dur = _duration_seconds(payload.get("activeDuration"))
    attrs = (
        f'workoutActivityType={quoteattr("HKWorkoutActivityType" + str(name))} '
        f'sourceName="Google Health" startDate={quoteattr(start)} endDate={quoteattr(end)}'
    )
    if dur:
        attrs += f' duration={quoteattr(str(dur / 60.0))} durationUnit="min"'
    dist = _first_numeric(metrics.get("distanceMeters"))
    if dist is not None:
        attrs += f' totalDistance={quoteattr(str(dist))} totalDistanceUnit="m"'
    kcal = _first_numeric(metrics.get("caloriesKcal"))
    if kcal is not None:
        attrs += f' totalEnergyBurned={quoteattr(str(kcal))} totalEnergyBurnedUnit="kcal"'
    return f" <Workout {attrs}/>"


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
DATA_TYPES = [
    "heart-rate",
    "heart-rate-variability",
    "daily-resting-heart-rate",
    "oxygen-saturation",
    "daily-respiratory-rate",
    "steps",
    "weight",
    "sleep",
    "exercise",
]


def main() -> None:
    parser = argparse.ArgumentParser(description="Export Google Health data as an Apple Health export.zip for NOOP.")
    parser.add_argument("--days", type=int, default=14, help="Number of days back to export (default 14).")
    parser.add_argument("--end", help="End date YYYY-MM-DD (default today, UTC).")
    parser.add_argument("--out", default="export.zip", help="Output path (.zip or .xml). Default export.zip.")
    parser.add_argument("--client-id")
    parser.add_argument("--client-secret")
    parser.add_argument("--refresh-token")
    parser.add_argument("--fitbit-grafana", default=str(DEFAULT_FITBIT_GRAFANA),
                        help="Path to a fitbit-grafana checkout for credential fallback.")
    parser.add_argument("--types", help="Comma-separated subset of data types to export "
                        f"(default all: {','.join(DATA_TYPES)}).")
    args = parser.parse_args()

    selected = DATA_TYPES
    if args.types:
        requested = [t.strip() for t in args.types.split(",") if t.strip()]
        unknown = [t for t in requested if t not in DATA_TYPES]
        if unknown:
            sys.exit(f"Unknown data type(s): {', '.join(unknown)}. Known: {', '.join(DATA_TYPES)}")
        selected = requested

    client_id, client_secret, refresh_token = load_credentials(args)
    token = get_access_token(client_id, client_secret, refresh_token)

    end = datetime.strptime(args.end, "%Y-%m-%d") if args.end else datetime.now(timezone.utc).replace(tzinfo=None)
    end = end.replace(hour=0, minute=0, second=0, microsecond=0, tzinfo=timezone.utc)
    days = [end - timedelta(days=i) for i in range(args.days - 1, -1, -1)]

    records: list[str] = []
    counts: dict[str, int] = {}
    for data_type in selected:
        per_type = 0
        for day in days:
            try:
                points = fetch_day(data_type, day, token)
            except urllib.error.HTTPError as err:
                print(f"  ! {data_type} {day:%Y-%m-%d}: HTTP {err.code}", file=sys.stderr)
                continue
            recs = build_records(data_type, points, counts)
            records.extend(recs)
            per_type += len(recs)
        print(f"  {data_type:28s} {per_type:>7d} records")

    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<!DOCTYPE HealthData [<!ELEMENT HealthData (Record|Workout)*>]>\n"
        '<HealthData locale="en_US">\n'
        + "\n".join(records)
        + "\n</HealthData>\n"
    )

    out_path = Path(args.out)
    if out_path.suffix.lower() == ".zip":
        with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("apple_health_export/export.xml", xml)
    else:
        out_path.write_text(xml)

    total = len(records)
    print(f"\nWrote {total} records ({sum(len(d) for d in [xml]) // 1024} KB XML) to {out_path}")
    print("Import it into NOOP (Strand): File -> Import -> select this file.")


if __name__ == "__main__":
    main()
