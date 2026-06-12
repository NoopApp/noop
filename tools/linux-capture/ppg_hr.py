#!/usr/bin/env python3
"""ppg_hr.py — derive a per-second heart rate from the WHOOP 5.0 type-47 **v26** optical PPG buffer.

Background (issue #156): the 5.0 historical store interleaves two type-47 record versions — v18 (the
per-second summary that carries HR + gravity/motion) and v26 (a 24 Hz optical PPG waveform, no motion).
v26 records are decoded to a raw `ppg_waveform` but otherwise have no consumer, so during the
v26-heavy stretches of a night the biometric timeline has HR gaps and motion is sparse, leaving sleep
hard to compute. The PPG is a real cardiac signal, though: this module recovers a per-second HR from it
so the timeline stays continuous (HR-driven, not actigraphy — PPG cannot give body motion).

The estimator is a windowed autocorrelation of the detrended waveform — the same method the
`analyze_v26_waveform.py` characterisation uses, applied per second over a sliding window. Pure and
stdlib-only so it is unit-testable with captured frames; the durable-store integration
(`derive_ppg_hr`) reads the already-stored `feat_ppg` samples and fills `feat_second.ppg_hr`.

Validate against the v18 ground truth on a capture:
    python3 ppg_hr.py capture_hist_ack.json
"""
import statistics
import struct
import sys

SAMPLE_RATE_HZ = 24            # v26 carries 24 samples per 1-second record
WINDOW_SECONDS = 8            # autocorrelation window — long enough for a stable low-HR estimate
HR_LO_BPM, HR_HI_BPM = 40, 200
MIN_CONFIDENCE = 0.30        # reject a window whose best autocorrelation peak is weaker than this


def _detrend(x, w=12):
    """Subtract a centred moving average (~1.7 beats wide) to remove DC / baseline wander."""
    out = []
    for i in range(len(x)):
        lo, hi = max(0, i - w), min(len(x), i + w + 1)
        out.append(x[i] - statistics.mean(x[lo:hi]))
    return out


def _acf(x, lag):
    """Normalised autocorrelation of `x` at `lag` (0 if the signal is flat)."""
    n = len(x) - lag
    if n <= 0:
        return 0.0
    m = statistics.mean(x)
    den = sum((xi - m) ** 2 for xi in x)
    return (sum((x[i] - m) * (x[i + lag] - m) for i in range(n)) / den) if den else 0.0


def estimate_hr(samples, fs=SAMPLE_RATE_HZ, lo_bpm=HR_LO_BPM, hi_bpm=HR_HI_BPM,
                min_confidence=MIN_CONFIDENCE):
    """Estimate heart rate (bpm) from one PPG window via autocorrelation.

    `samples` is the raw 24 Hz waveform (ADC counts). Returns `(bpm, confidence)` where confidence is
    the peak normalised autocorrelation (0..1), or `None` when the window is too short or no pulsatile
    peak clears `min_confidence` (flat/garbage PPG → no fabricated HR)."""
    if len(samples) < fs * 3:                      # need >= 3 s to resolve a low HR
        return None
    x = _detrend(samples)
    lo_lag = max(2, round(fs * 60 / hi_bpm))
    hi_lag = min(len(x) - 2, round(fs * 60 / lo_bpm))
    if hi_lag <= lo_lag:
        return None
    vals = {lag: _acf(x, lag) for lag in range(lo_lag, hi_lag + 1)}
    peak = max(vals.values())
    if peak < min_confidence:
        return None
    # Pick the FUNDAMENTAL period: the smallest-lag local maximum that is nearly as strong as the
    # global peak. Autocorrelation also peaks at 2×/3× the true period (half/third HR); taking the
    # global max there would report half the real rate, so prefer the shortest prominent period.
    best_lag = None
    for lag in range(lo_lag + 1, hi_lag):
        if vals[lag] >= 0.85 * peak and vals[lag] >= vals[lag - 1] and vals[lag] >= vals[lag + 1]:
            best_lag = lag
            break
    if best_lag is None:                           # no clean local max → fall back to the global peak
        best_lag = max(vals, key=vals.get)
    return round(fs * 60 / best_lag, 1), round(vals[best_lag], 3)


# --- v26 frame helpers (mirror analyze_v26_waveform.py / decodeWhoop5HistoricalV26) ----------------
WAVE_START, WAVE_END = 27, 75   # 24 LE-i16 PPG samples


def _u32le(r, o):
    return r[o] | (r[o + 1] << 8) | (r[o + 2] << 16) | (r[o + 3] << 24)


def v26_record(frame):
    """If `frame` is a type-47 v26 record, return (unix, channel, [24 samples]); else None."""
    if len(frame) != 88 or frame[8] != 47 or frame[9] != 26:
        return None
    samples = [struct.unpack("<h", frame[i:i + 2])[0] for i in range(WAVE_START, WAVE_END - 1, 2)]
    channel = frame[21] if 1 <= frame[21] <= 26 else 0
    return _u32le(frame, 15), channel, samples


def hr_series(records, fs=SAMPLE_RATE_HZ, window_s=WINDOW_SECONDS):
    """Per-second PPG-HR over a list of (unix, channel, samples) v26 records.

    Records are grouped into consecutive-second runs of the SAME optical channel (PPG phase is only
    continuous within such a run); a window centred on each second is autocorrelated. Returns a list of
    `(unix, bpm, confidence)`, one per second that yielded a confident estimate."""
    by_key = {}
    for unix, ch, samples in records:
        by_key.setdefault(ch, {})[unix] = samples
    out = []
    half = window_s // 2
    for ch, secs in by_key.items():
        order = sorted(secs)
        # split into consecutive-second runs
        runs, cur = [], [order[0]] if order else []
        for u in order[1:]:
            if u - cur[-1] == 1:
                cur.append(u)
            else:
                runs.append(cur); cur = [u]
        if cur:
            runs.append(cur)
        for run in runs:
            if len(run) < 3:
                continue
            for t in run:
                win = [u for u in run if t - half <= u <= t + half]
                if len(win) < 3:
                    continue
                sig = []
                for u in win:
                    sig += secs[u]
                est = estimate_hr(sig, fs=fs)
                if est:
                    out.append((t, est[0], est[1]))
    out.sort()
    return out


# --- durable-store integration --------------------------------------------------------------------

def derive_ppg_hr(conn, device_id):
    """Fill `feat_second.ppg_hr` for a device from its stored `feat_ppg` samples. Idempotent.

    Returns the number of seconds written. Requires the `ppg_hr` column (added by decode_features'
    apply_schema). Reconstructs each second's 24-sample waveform from feat_ppg, runs `hr_series`, and
    upserts the result — never overwrites the measured v18 `hr`, only the separate ppg_hr column."""
    rows = conn.execute(
        "SELECT unix, channel, sample_idx, value FROM feat_ppg WHERE device_id=? "
        "ORDER BY channel, unix, sample_idx", (device_id,)).fetchall()
    if not rows:
        return 0
    buckets = {}
    for unix, ch, idx, val in rows:
        buckets.setdefault((ch, unix), []).append((idx, val))
    records = [(unix, ch, [v for _, v in sorted(s)]) for (ch, unix), s in buckets.items()]
    series = hr_series(records)
    for unix, bpm, conf in series:
        conn.execute(
            "INSERT INTO feat_second (device_id, unix, ppg_hr, ppg_hr_conf) VALUES (?,?,?,?) "
            "ON CONFLICT(device_id, unix) DO UPDATE SET ppg_hr=excluded.ppg_hr, "
            "ppg_hr_conf=excluded.ppg_hr_conf",
            (device_id, unix, bpm, conf))
    conn.commit()
    return len(series)


def _validate(path):
    """Validate PPG-HR against the v18 same-timestamp HR on a capture.json (no DB needed)."""
    import json
    frames = [bytes.fromhex(c["hex"] if isinstance(c, dict) else c) for c in json.load(open(path))]
    records = [r for r in (v26_record(f) for f in frames) if r]
    v18_hr = {_u32le(f, 15): f[22] for f in frames if len(f) == 124 and f[8] == 47 and f[9] == 18}
    if not records:
        print(f"no v26 records in {path}")
        return
    series = hr_series(records)
    errs = [abs(bpm - v18_hr[t]) for t, bpm, _ in series if t in v18_hr]
    print(f"{path}: {len(records)} v26 records → {len(series)} per-second PPG-HR estimates")
    if series:
        confs = [c for _, _, c in series]
        print(f"  PPG-HR: {min(b for _,b,_ in series):.0f}..{max(b for _,b,_ in series):.0f} bpm, "
              f"confidence mean {statistics.mean(confs):.2f}")
    if errs:
        errs.sort()
        print(f"  vs v18 ground truth ({len(errs)} overlapping seconds): "
              f"mean |Δ| {statistics.mean(errs):.1f} bpm, median {errs[len(errs)//2]:.1f}, "
              f"≤5 bpm on {100*sum(e<=5 for e in errs)//len(errs)}%")
    else:
        print("  (no overlapping v18 seconds to validate against in this capture)")


if __name__ == "__main__":
    _validate(sys.argv[1] if len(sys.argv) > 1 else "capture_hist_ack.json")
