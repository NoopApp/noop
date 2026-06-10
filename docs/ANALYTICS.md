# NOOP Analytics

On-device analytics for **NOOP** — a standalone, fully offline companion app for WHOOP straps (4.0 and 5.0). NOOP talks to *your own* strap over Bluetooth, stores everything locally in SQLite, and computes recovery, strain, HRV, and sleep on-device. There is no cloud and no account involved in any of the math described here.

> **Not affiliated with WHOOP.** NOOP interoperates with hardware and data you already own. The metrics below are **approximations** of common exercise-physiology and HRV methods, derived from published literature — they are **not** reproductions of any proprietary scoring model, and they are **not a medical device**. Nothing here is medical advice.

All analytics live in the cross-platform `StrandAnalytics` Swift package. Every entry point is a **pure, deterministic, DB-free** function over its inputs — no I/O, no global state, no network. Persistence and BLE are wired in elsewhere (`WhoopStore`, the app target). This makes the whole package straightforward to unit-test against fixed vectors.

- Package: `Packages/StrandAnalytics/Sources/StrandAnalytics/`
- Top-level index: `StrandAnalytics.swift` (`StrandAnalytics.version == "0.1.0"`)
- App reference implementation: `Strand/` (macOS SwiftUI)

---

## What is actually wired into the app

The package contains more analytics than the app currently calls. This section is the honest map of **library-only** vs **live**, verified against the app sources.

| Engine | File | Status in the macOS app |
|---|---|---|
| `HRVAnalyzer` | `HRVAnalyzer.swift` | **Library-only** as a type. The app computes RMSSD inline via `AppModel.rmssd(_:)` (same Task-Force formula) for the live stress nudge. |
| `RecoveryScorer` | `RecoveryScorer.swift` | **Live.** Runs inside `AnalyticsEngine.analyzeDay` via `Strand/Data/IntelligenceEngine.swift`; computed recoveries are persisted under the `"<deviceId>-noop"` source and merged **under** any imported `recovery_score_pct` (imports always win). APPROXIMATE. |
| `StrainScorer` | `StrainScorer.swift` | **Live.** Day strain is computed on-device for nights the strap offloaded; the imported `day_strain` column still wins for imported days. APPROXIMATE. |
| `SleepStager` | `SleepStager.swift` | **Live.** Stages each offloaded night inside `analyzeDay`; computed sessions are persisted under the `"-noop"` source, with imported sleeps taking precedence. APPROXIMATE. |
| `Baselines` | `Baselines.swift` | **Live.** Seeds the recovery baseline in `IntelligenceEngine.analyzeRecent` (two-pass cold-start). The illness early-warning in `AppModel` still uses its own trailing-window baseline math inline (see below). |
| `WorkoutDetector` / `Calories` | `WorkoutDetector.swift` | **Live.** Runs inside `AnalyticsEngine.analyzeDay`; detected bouts are persisted as `workout` rows under the computed `"<deviceId>-noop"` source (sport `"detected"`), de-duplicated against imported WHOOP workouts. All intensity/calorie fields are APPROXIMATE. Not yet surfaced in the Workouts screen. |
| `AnalyticsEngine` | `AnalyticsEngine.swift` | **Live orchestrator.** `analyzeDay(...)` is called by `Strand/Data/IntelligenceEngine.swift` — every 15 minutes while connected, and from the Intelligence screen — and its `DailyMetric`, sleep sessions and detected workouts are persisted under the `"-noop"` source. |
| `HRZones` | `HRZones.swift` | **Library-only** (display zone model). The app's live zone coaching computes `%HRmax` inline in `AppModel.coachZone(_:)`. |
| `CorrelationEngine` | `CorrelationEngine.swift` | **Live.** Used by `InsightsView`, `CompareView`, `MetricExplorerView`. |
| `BehaviorInsights` | `BehaviorInsights.swift` | **Live.** Used by `InsightsView` (`rank` + `sentence`). |
| `ComparisonEngine` | `ComparisonEngine.swift` | **Live.** Used by `MetricExplorerView`. |

**In short:** the *interactive data-interrogation* engines (correlation, behavior effects, period comparison) are wired into screens, and the *recompute-from-raw-streams* engines (recovery, strain, sleep staging, workout detection) run live too: `IntelligenceEngine` calls `analyzeDay` for every night the strap offloaded and persists the APPROXIMATE results under the `"-noop"` source, merged under any imported rows — a WHOOP export still wins wherever it covers a day. The live BLE app additionally runs four small inline analytics in `AppModel`: HR smoothing, RMSSD, HR-zone coaching, an illness/strain early-warning, and a resting-stress nudge.

---

## Live analytics in `AppModel`

Source: `Strand/App/AppModel.swift`. These run against the live BLE stream and the daily history, on the main actor.

### 1. Heart-rate smoothing (`ingestHR`)

Every screen shows a **smoothed** bpm (`AppModel.bpm`), never the raw per-beat value (which swings with HRV). The smoother:

1. Prefers the strap's reported HR; falls back to `60000 / RR` (last R-R interval) if needed.
2. Clamps to a plausible `30…220` bpm range — rejects `0` and garbage spikes.
3. Keeps a ~10-second sliding window (max 40 samples) and **publishes the window median**.

```swift
hrWindow.append((now, inst))
hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10 s window
if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
let vals = hrWindow.map(\.v).sorted()
bpm = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
```

Median (not mean) is deliberate: it rejects single-beat outliers without lagging the signal.

### 2. RMSSD for the stress nudge (`rmssd` + `evaluateStress`)

The live RMSSD uses the classic Task-Force successive-difference formula over a rolling R-R buffer:

```swift
static func rmssd(_ rr: [Int]) -> Double {
    guard rr.count >= 2 else { return 0 }
    var sum = 0.0, n = 0
    for i in 1..<rr.count { let d = Double(rr[i] - rr[i - 1]); sum += d * d; n += 1 }
    return n > 0 ? (sum / Double(n)).squareRoot() : 0
}
```

`evaluateStress()` is an **experimental, off-by-default** resting-stress nudge:

- Only runs when `behavior.stressNudge` is on **and** the strap is bonded **and** worn.
- Filters R-R to plausible beats (`300 < rr < 2000` ms, i.e. 30–200 bpm), keeps the last 60, needs ≥ 20.
- Tracks a **slow HRV baseline** as an EWMA: `hrvBaseline = hrvBaseline * 0.98 + rmssd * 0.02`.
- Only fires when HR is in a **resting band** (`55…100` bpm — not a workout) and current RMSSD has dropped **below 60% of baseline**.
- Rate-limited to **once per 15 minutes** (`> 900` s). On fire it buzzes the strap once and logs "take a paced breath."

It is intentionally conservative so it rarely false-fires.

### 3. HR-zone haptic coaching (`coachZone`)

Watches the smoothed `bpm`, computes `%HRmax` from `profile.hrMax`, and buckets into 5 zones at `0.6 / 0.7 / 0.8 / 0.9` of max:

```swift
let pct = Double(hr) / maxHR
let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
```

On crossing **into zone 5** it buzzes three times ("ease off"); on dropping back **to zone ≤ 1** it buzzes once ("recovered"). Gated on `behavior.zoneCoaching`, bonded, worn, and a valid `hrMax`.

### 4. Illness / strain early-warning (`evaluateIllness`)

This is the live, app-side version of the baseline-comparison idea. It recomputes whenever the daily history changes (`repo.$days`). It compares the **last ~2 days** against a **~28-day baseline ending 3 days ago** (so the recent window doesn't contaminate its own baseline):

```swift
let recent = Array(days.suffix(2))
let base   = Array(days.suffix(31).dropLast(3))   // ~28 days ending 3 days ago
```

It then flags anomalies against simple, explainable thresholds using `DailyMetric` fields:

| Signal | Field(s) | Anomaly condition |
|---|---|---|
| Resting HR ↑ | `restingHr` | recent mean ≥ baseline mean **+ 5 bpm** |
| HRV ↓ | `avgHrv` | recent mean ≤ baseline mean **× 0.80** (−20%) |
| Skin temp ↑ | `skinTempDevC` | recent mean deviation **≥ +0.6 °C** |
| Respiration ↑ | `respRateBpm` | recent mean ≥ baseline mean **+ 1.5 bpm** |

A banner appears only when **two or more** anomalies fire together — the classic early-illness signature is *RHR up + HRV down + skin-temp up*. Requires `behavior.illnessWatch` on and at least 14 days of history. On-device only; the message is a plain-English summary like *"Your body looks strained — resting HR +6 bpm, HRV −22%. Consider taking it easy."*

---

## `HRVAnalyzer` — RMSSD / SDNN with cleaning

Source: `HRVAnalyzer.swift`. Reproduces the **Task Force (1996)** definitions over R-R / NN intervals (ms), with a deterministic cleaning pipeline.

### Formulas

```
RMSSD = sqrt( (1/(N-1)) · Σ (NN[i+1] − NN[i])² )    (Task Force 1996)
SDNN  = sample standard deviation of NN, ddof = 1     (Task Force 1996)
pNN50 = 100 · (count of |ΔNN| > 50 ms) / (N − 1)
```

`rmssdRaw(_:)` and `sdnnRaw(_:)` are the raw primitives (no filtering, return `nil` for fewer than 2 values).

### Cleaning pipeline (`cleanRR`)

1. **Range filter** — drop intervals outside `[rrMinMs, rrMaxMs] = [300, 2000]` ms (≈ 200 bpm to 30 bpm).
2. **Ectopic rejection (Malik-style)** — drop any beat deviating more than `ectopicThreshold = 0.20` (20%) from a **local median** over a centered window of `2·ectopicWindowRadius + 1 = 5` beats. Beats with too small a neighbourhood are kept.
3. **Sufficiency gate** — require at least `minBeats = 20` clean intervals before returning a trustworthy result; otherwise `HRVResult.empty(...)`.

> **Honest substitution.** The reference Python pipeline ran neurokit2's Kubios / Lipponen–Tarvainen (2019) artifact classifier, which isn't available on-device. NOOP substitutes the classical **Malik et al. (1989)** 20%-local-median rule — a simpler, fully deterministic approximation of the same intent (remove physiologically impossible beat-to-beat jumps before computing HRV). It does not model the missed/extra-beat insertion that Kubios does.

### API

```swift
HRVAnalyzer.analyze(_ rr: [RRInterval], windowStart: Int?, windowEnd: Int?) -> HRVResult
HRVAnalyzer.analyze(rawRR: [Double]) -> HRVResult
```

`HRVResult` carries `rmssd`, `sdnn`, `meanNN`, `pnn50`, plus `nInput` and `nClean` (counts before/after cleaning) for transparency.

---

## `RecoveryScorer` — transparent 0–100 recovery composite

Source: `RecoveryScorer.swift`. A **z-score + logistic** composite. It is explicitly **approximate** — HRV-dominant and baseline-normalized — and makes no claim to reproduce WHOOP's proprietary recovery model.

### Weighting

| Driver | Direction | Weight |
|---|---|---|
| HRV vs baseline | higher → better recovery | `wHRV = 0.60` (dominant) |
| Resting HR vs baseline | lower → better | `wRHR = 0.20` |
| Respiration vs baseline | lower → better | `wResp = 0.05` |
| Sleep performance | higher → better | `wSleep = 0.15` |

Each metric is standardized to a **robust z-score** against the personal baseline (EWMA spread):

```
z = (value − mean) / (1.253 · spread)
```

The `1.253` converts an EWMA mean-absolute-deviation into an approximate Gaussian σ (`E[|X−μ|] = σ·√(2/π) ≈ σ/1.253`). For "lower is better" drivers (RHR, resp) the z is inverted by swapping value and mean. The sleep term is centered directly: `(sleepPerf − 0.85) / 0.12`.

Missing terms are dropped and weights renormalized. The weighted-mean z is squashed:

```
score = 100 / (1 + exp(−logisticK · (z − logisticZ0)))
        logisticK  = 1.6     (±2 z ≈ the full red–green band)
        logisticZ0 = −0.20   (anchors z = 0 → ~58 %)
```

The `58%` anchor matches WHOOP's published population-average recovery (`populationMean = 58.0`).

### Cold-start

HRV is the dominant driver. If its baseline isn't usable yet (`BaselineState.usable == false`, i.e. fewer than `minNightsSeed` valid nights), `recovery(...)` returns `nil` — more honest than fabricating a number. Callers may fall back to `populationMean` but should flag it.

### Bands (`band(_:)`)

| Band | Range |
|---|---|
| red | `< 34` |
| yellow | `34 … 67` |
| green | `≥ 67` |

### Resting HR (`restingHR`)

"Lowest sustained HR" during the in-bed window = the **minimum of 5-minute non-overlapping bin means** of HR samples in `[start, end]`. This rejects single-beat dips while capturing the night's true floor.

---

## `StrainScorer` — 0–21 logarithmic cardiovascular load

Source: `StrainScorer.swift`. An **independent** implementation of published exercise-physiology methods (WHOOP-*like*, not a reproduction).

### Pipeline

1. **Heart-Rate Reserve (Karvonen 1957):** `HRR = HRmax − RHR`.
2. **Per-sample intensity** as `%HRR = (HR − RHR) / HRR × 100`, clamped `[0, 100]`.
3. **TRIMP accumulation** over the window, by one of two methods:
   - **Edwards (1993) 5-zone summation (default):** each sample contributes its zone weight (`1…5` at the `50 / 60 / 70 / 80 / 90 %HRR` cut-offs) × duration.
   - **Banister (1991) exponential:** each sample contributes `duration × x × 0.64 × e^(b·x)`, where `x = %HRR/100` and `b = 1.92` (men) / `1.67` (women).
4. **Logarithmic compression** onto `[0, 21]`:

```
strain = 21 · ln(TRIMP + 1) / ln(D),    D = strainDenominator = 7201
```

`D = 7201` is calibrated so the Edwards daily ceiling — top zone weight 5 sustained for 24 h = `5 × 1440 = 7200` — maps to exactly `21.0` (`ln(7201)/ln(7201) = 1`).

### HRmax estimation (`estimateHRmax`)

- With ≥ `hrmaxMinSamples = 600` HR samples, use the observed `99.5th` percentile (`"observed"`), unless a Tanaka estimate is higher.
- **Tanaka (2001):** `HRmax = 208 − 0.7 × age` (gender-independent), used as the floor / fallback (`"tanaka"`).
- No data and no age → `(0, "unknown")`.

### Guards & gates

- Returns `nil` with fewer than `minReadings = 600` samples (≈ 10 min at 1 Hz) or when `HRmax ≤ RHR` (invalid HRR).
- Per-sample duration is inferred from the first two timestamps, falling back to `1 s`.

### Denominator calibration (`fitStrainDenominator`)

Given `(TRIMP, reference_strain)` pairs, fits `D` via a through-origin least-squares line in log-space: `ln(D) = 21 · Σx² / Σ(x·strain)`, `x = ln(TRIMP+1)`. Throws on fewer than 2 usable pairs.

---

## `SleepStager` — sleep/wake detection + approximate 4-class staging

Source: `SleepStager.swift`. Detects in-bed sessions from gravity/HR/RR/respiration and produces a 30-second hypnogram of `{wake, light, deep, rem}`.

> **Honest hedging.** These stages are **approximations**, not PSG-validated, not medical advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019). **Light/deep separation is the weakest link — deep-minute estimates are the least reliable output.**

### Stage 0 — gravity-stillness sleep/wake spine (`detectSleep`)

- Per-record movement proxy = L2 magnitude of the gravity-vector change vs the previous record (`gravityDeltas`).
- A sample is "still" if its delta < `gravityStillThresholdG = 0.01 g`. A rolling window (`stillWindowMin = 15` min) calls its center "sleep" when ≥ `stillFraction = 0.70` of samples are still.
- Contiguous runs are built, breaking on a class change or a data gap > `maxGapMin = 20` min; runs shorter than `mergeMin = 15` min are absorbed into neighbours.
- A run must exceed `minSleepMin = 60` min to count, and is **HR-confirmed**: mean HR over the run must be ≤ `hrSleepBaselineMult = 1.05 ×` the day's median HR (skipped when fewer than 30 HR samples — gravity is trusted alone).
- A citable **te Lindert 30 s Cole–Kripke** index (`SI = 0.001 · Σ wᵢ·Aᵢ`, sleep iff `SI < 1`, weights `[106, 54, 58, 76, 230, 74, 67]`) is computed per epoch as a cross-check and to find onset / final-wake.

### Stage 1 — per-epoch cardiorespiratory features

Over a rolling 5-minute window per 30 s epoch:

- mean HR;
- **Walch difference-of-Gaussians HR variability** (`σ1 = 120 s` minus `σ2 = 600 s`, reflect-padded convolution; NaNs linearly interpolated);
- **RMSSD / SDNN** from range-filtered R-R (`HRVAnalyzer.rmssdRaw` / `sdnnRaw`);
- **respiration rate + RRV** from the raw 1 Hz resp channel via a simple peak detector (detrend → local-maxima peaks ≥ 2 s apart → breath intervals 1.5–12 s → rate = `60 / median interval`, RRV = std of intervals).

> Frequency-domain HRV (HF, LF/HF) is **omitted** — there is no neurokit2/scipy on-device — so the parasympathetic-tone signal is **RMSSD only**. The respiration peak-finder is a faithful port (the reference derived these "robustly ourselves" too, without neurokit).

### Stage 2 — percentile-band classifier (`classifyOne`)

Reference distributions are taken over the session's **sleep-period** epochs (Cole–Kripke = sleep). A motion fraction and the per-epoch features are compared against session-relative percentiles:

| Class | Rule |
|---|---|
| **wake** | sustained motion (`moveFrac ≥ 0.15`) **and** activated cardiac (high HR or high DoG-HR variability), or no HR to vet the motion |
| **deep** | still (`moveFrac ≤ 0.10`) **and** high parasympathetic tone (RMSSD ≥ 70th pct) **and** low HR (≤ 25th pct) **and** regular respiration |
| **rem** | still body **and** activated cardiac **and** irregular respiration (RRV ≥ 65th pct); a fallback requires both cardiac signals when respiration is unavailable |
| **light** | everything else (the default) |

### Stage 3 — smoothing + physiology re-imposition

- 5-epoch **median smoothing** of the label sequence (`smoothLabels`).
- **No REM in the first 15 min** after onset (`reimposePhysiology` → demote to light).
- **No deep after the first third** of the night (deep is biased early) → demote to light.
- Pre-onset and post-final-wake epochs are forced to `wake`.

Consecutive same-stage epochs are merged into `StageSegment`s tiling `[start, end]`.

### Outputs

- `SleepSession` — `start`, `end`, `efficiency` (AASM `asleep / in-bed`, where `asleep = in-bed − wake`), `stages`, per-session `restingHR` (lowest 5-min rolling-mean HR) and `avgHRV` (mean RMSSD over 5-min tumbling windows).
- `hypnogramMetrics(_:)` — AASM-style roll-up: TIB / TST / SPT / SOL / REM latency / WASO / efficiency / disturbances, plus deep/REM/light minutes and percentages.

---

## `Baselines` — personal rolling baselines

Source: `Baselines.swift`. Per-metric personal baselines that `RecoveryScorer` consumes. Two interchangeable paths produce the same `BaselineState` shape.

### 1. Winsorized EWMA (production model — `update` / `foldHistory`)

A robust, recency-weighted center with an EWMA-of-absolute-deviation spread tracker:

- **Half-life → smoothing factor:** `λ = 1 − 0.5^(1/halfLife)`. Center half-life 14 nights; spread half-life 21 (slower).
- **Sanity gate:** values outside `[minVal, maxVal]` (per-metric) → skip-and-hold.
- **Hard outlier rejection:** once seeded, a value > `hardOutlierK = 5 ×` spread away is seen but not folded.
- **Winsor clamp:** fold only within `± winsorK = 3 ×` spread of the current baseline, so a single big night can't yank the center; the **spread** uses the unclamped deviation so real change is still tracked.

```swift
let clamped = max(lo, min(hi, value))                       // ±3·spread
let newBaseline = lb * clamped + (1 - lb) * state.baseline
let newSpread   = max(cfg.floorSpread, ls * abs(value - newBaseline) + (1 - ls) * state.spread)
```

### 2. Trailing-window mean/SD (`rollingMeanSD`)

The simple, maximally auditable path: plain mean and sample SD (ddof = 1) over the trailing N (default 30) valid nights, with the σ floor applied and converted back into abs-dev space (`÷ 1.253`) so `deviation()` recovers the intended Gaussian σ unchanged.

### Status lifecycle (`BaselineStatus`)

| Status | Condition |
|---|---|
| `calibrating` | fewer than `minNightsSeed = 4` valid nights (no score yet) |
| `provisional` | `4 … 13` valid nights (usable, higher uncertainty) |
| `trusted` | ≥ `minNightsTrust = 14` valid nights |
| `stale` | usable but no update for > `staleDays = 14` nights |

### Per-metric config (`metricCfg`)

| Metric | min | max | floor spread | center / spread half-life |
|---|---|---|---|---|
| `hrv` | 5 | 250 | 5.0 | 14 / 21 |
| `resting_hr` | 30 | 120 | 2.0 | 14 / 21 |
| `resp` | 4 | 40 | 0.5 | 14 / 21 |
| `skin_temp` | 20 | 42 | 0.3 | 14 / 21 |

### Deviation

`deviation(_:state:)` returns a robust z-score, a signed physical-units delta, a fractional ratio (`value/baseline − 1`), and an `inNormalRange` flag (`|z| ≤ 1`).

---

## `WorkoutDetector` + `Calories` — retroactive workout detection

Source: `WorkoutDetector.swift`. Finds workouts in the stored 1 Hz HR + gravity streams (no manual logging).

A workout is a **sustained window** (≥ `minExerciseMin = 5` min) where **both** gates hold per sample:

- **Elevated HR** — above `RHR + hrMarginBPM (15 bpm)`. RHR defaults to the day's 10th-percentile HR.
- **Sustained motion** — gravity-derived intensity (10-second trailing mean) above `motionThreshold = 0.20`.

Active samples are grouped into runs (merging gaps < `mergeGapS = 150 s`), then qualified by intensity: ≥ `minIntensityZ2Plus = 0.50` of the bout in Edwards zone 2+. Per bout it reports avg/peak HR, duration, Edwards zone-time %, mean `%HRR`, strain (via `StrainScorer`), and calories.

### Calories (`Calories.estimateBoutCalories`)

Per-second blend of **Keytel (2005)** active expenditure and **revised Harris–Benedict** BMR (resting), with sex-specific coefficients (`male` / `female` / `nonbinary`). Below a `RHR + 0.30 × HRR` threshold the resting rate is used; above it, the HR-driven active rate. Returns `(kcal, kJ)`. **Approximate** — not laboratory calorimetry.

---

## Interactive engines (wired into screens)

These are the **live** data-interrogation engines, used by `InsightsView`, `CompareView`, and `MetricExplorerView`.

### `CorrelationEngine`

Source: `CorrelationEngine.swift`. Pearson r, OLS regression, and an approximate two-sided p-value between two daily series.

```
r         = Σ(x−x̄)(y−ȳ) / sqrt( Σ(x−x̄)² · Σ(y−ȳ)² )
slope     = Σ(x−x̄)(y−ȳ) / Σ(x−x̄)²          (OLS, y on x)
intercept = ȳ − slope·x̄
t         = r · sqrt( (n−2) / (1−r²) )
p         = 2·(1 − Φ(|t|))                  (normal approximation)
```

- Returns `nil` for fewer than 3 pairs or zero variance in either variable.
- Φ uses the Abramowitz & Stegun 7.1.26 `erf` approximation. The normal approximation slightly **understates** p for small n (true Student-t tails are heavier) but is fully deterministic with no special-function tables.
- `alignByDay(...)` inner-joins two `yyyy-MM-dd`-keyed series; `lagged(x:y:lagDays:)` shifts y forward by `lagDays` (UTC day arithmetic) to probe directional/delayed effects — e.g. *today's strain vs tomorrow's recovery*.

### `BehaviorInsights`

Source: `BehaviorInsights.swift`. The headline "does this behavior move an outcome?" feature. Splits days where a behavior was logged (e.g. *Alcohol*, *Late meal*, *Meditation*) from days it was not, and compares an outcome metric between the groups.

For each behavior/outcome it reports group means, signed `delta`, `pctChange`, **Cohen's d** (pooled SD), and a **Welch t-test** p-value (unequal variances, Welch–Satterthwaite df, normal-approx tail):

```
sp = sqrt( ((n1−1)·s1² + (n2−1)·s2²) / (n1+n2−2) )     d = (m1 − m2) / sp
t  = (m1 − m2) / sqrt(s1²/n1 + s2²/n2)
```

- `significant` requires `p < 0.05` **and** `min(nWith, nWithout) ≥ 5` (guards against spurious "significance" from a handful of days).
- `rank(...)` orders effects by `|d|` descending, significant first.
- `sentence(_:)` renders plain English, e.g. *"On days you logged 'Alcohol', Recovery was 12% lower (avg 61 vs 69, n=140 vs 498)."*

### `ComparisonEngine`

Source: `ComparisonEngine.swift`. Period-over-period comparison of one daily metric.

- `stat(_:)` → `SeriesStat`: mean, median, min, max, sample SD (ddof = 1), n, and least-squares slope-per-day (OLS against the 0-based index).
- `compare(current:previous:)` → `PeriodComparison`: signed `delta` on the means, `pctChange` (nil when the previous mean is 0/empty), and a coarse `direction` (`-1/0/+1`).
- `monthOverMonth(byDay:referenceDay:)` splits a `yyyy-MM-dd` series on the `yyyy-MM` prefix (locale/timezone-free) into the reference month vs the immediately preceding calendar month.

---

## The library orchestrator: `AnalyticsEngine`

Source: `AnalyticsEngine.swift`. A pure function that ties the recompute engines together for one day. **Implemented and tested, but not yet wired into the import/store pipeline** — the importers currently copy WHOOP's own per-day recovery/strain/sleep numbers from your export.

`analyzeDay(day:hr:rr:resp:gravity:profile:baselines:maxHROverride:)` runs, in order:

1. `SleepStager.detectSleep` → keep sessions whose `end` falls on `day` (UTC) — a night ending that morning.
2. Daily sleep aggregates (in-bed-weighted efficiency; deep/REM/light minutes; disturbances) via `hypnogramMetrics`.
3. Daily resting HR = lowest per-session resting HR; daily avg HRV = in-bed-weighted mean of per-session HRV.
4. `RecoveryScorer.recovery(...)` with the personal HRV/RHR/resp baselines and the efficiency-based sleep-performance proxy.
5. `StrainScorer.strain(...)` over the full day's HR window (Tanaka HRmax from age unless overridden).
6. `WorkoutDetector.detect(...)`.

It assembles a `DailyMetric` (the `WhoopStore` cache shape) plus rich `SleepSession`s and `CachedSleepSession` cache rows. Every derived value is **approximate** by construction.

---

## Data flow summary

```
WHOOP strap (BLE) ─┐
                   ├─► WhoopProtocol (frame decode) ─► WhoopStore (SQLite, 1 Hz streams)
WHOOP CSV export ──┤                                         │
Apple Health XML ──┘                                         │
                                                             ▼
   importers copy per-day recovery / strain / sleep ──► DailyMetric (metrics cache)
                                                             │
                          ┌──────────────────────────────────┤
                          ▼                                   ▼
   AnalyticsEngine.analyzeDay (recompute path,        Repository.days ─► TodayView,
   library-only today: HRV/recovery/strain/sleep      InsightsView (CorrelationEngine,
   from raw streams)                                   BehaviorInsights), CompareView,
                                                       MetricExplorerView (ComparisonEngine)

   live BLE stream ─► AppModel: HR smoothing · RMSSD · zone coaching ·
                       illness early-warning · resting-stress nudge
```

---

## Conventions & honesty notes

- **Approximate by design.** Recovery, strain, sleep stages, workout intensity, and calories are transparent approximations of published methods — not reproductions of any proprietary algorithm. Each engine's source header states exactly where it approximates (e.g. Malik instead of Kubios; RMSSD-only parasympathetic tone; normal-approx p-values).
- **Deterministic.** No randomness, no wall-clock dependence inside the math, no DB/network access. Same inputs → same outputs, which makes the package unit-testable against fixed vectors.
- **Robust statistics.** z-scores use EWMA mean-absolute-deviation (`× 1.253` to a Gaussian σ); resting HR uses 5-minute bin minima; HR display uses windowed medians — all chosen to resist single-sample outliers.
- **Cold-start honesty.** When a baseline isn't trustworthy yet, the recovery scorer returns `nil` rather than a fabricated number.
- **Not a medical device.** None of this is diagnostic or medical advice. The illness early-warning is a wellness nudge from your own baselines, not a clinical screen.
- **Not affiliated with WHOOP.** NOOP interoperates with hardware and exports you already own, entirely on-device. Protocol decoding builds on community reverse-engineering of the WHOOP 4.0 (project *my-whoop*, `johnmiddleton12/my-whoop`) and WHOOP 5.0 (project *goose*, `b-nnett/goose`) protocols.
