<p align="center">
  <img src="docs/assets/banner.svg" alt="NOOP — a local-first companion for WHOOP straps" width="860">
</p>

<h1 align="center">NOOP</h1>

<p align="center"><b>Your strap. Your data. Your machine. Local-first, no cloud.</b></p>

<p align="center">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Android%20%C2%B7%20iOS-18C98B?style=flat-square">
  <img alt="Local first" src="https://img.shields.io/badge/local-first-18C98B?style=flat-square">
  <img alt="Account free" src="https://img.shields.io/badge/account-free-2FE6A8?style=flat-square">
  <img alt="WHOOP 4 and 5" src="https://img.shields.io/badge/works%20with-WHOOP%204.0%20%26%205.0-8B9690?style=flat-square">
  <a href="LICENSE"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-8B9690?style=flat-square"></a>
</p>

<p align="center">
  <a href="#keeping-noop-alive">♥&nbsp;Support</a> ·
  <a href="#download">⬇&nbsp;Download</a> ·
  <a href="#features">Features</a> ·
  <a href="docs/PROTOCOL.md">Protocol</a> ·
  <a href="mailto:thenoopapp@gmail.com">Contact</a>
</p>

---

## Keeping NOOP alive

NOOP is **free, forever** — no account, no cloud, no subscription, every feature unlocked, no nag. That doesn't change.

But here's the honest reality, up front: **NOOP is built and maintained by one person, out of pocket.** Reverse-engineering WHOOP's hardware — and keeping up as its firmware changes — takes real time and real test hardware. **The project continues if the people who use it help fund it. If that doesn't happen, it can't.** No drama, no guilt — just the maths of an unfunded project.

If NOOP saves you a subscription, or you just want WHOOP 5.0/MG support finished and the work to keep going, **chipping in is what genuinely decides that.** It's optional, one-off, and tied to nothing about your data or access — there's no server and no record of who has or hasn't.

### How to donate — 2 minutes, even if you've never touched crypto

Donations are **crypto-only**, on purpose: staying anonymous (for the project *and* for you) rules out PayPal, Patreon, or anything with a name attached. If you don't already hold any:

1. **Install a mainstream exchange app** — Coinbase, Binance, Kraken, or **Cash App** (Cash App handles Bitcoin directly).
2. **Buy a small amount of Bitcoin (BTC) or Ethereum (ETH)** — even $5–10 is genuinely helpful.
3. **Tap Send / Withdraw, paste the matching address below, and send.** That's it. (Only ever send a coin to its own network.)

| Coin | Network | Address |
|---|---|---|
| **BTC** | Bitcoin | `bc1qn2gkl7wslwpws06mvazjn2uu689zlkv7kg3kf5` |
| **ETH** | Ethereum | `0xd64D508b531c4b1297Ca4023C774e0E97aA67B7F` |
| **ADA** | Cardano | `addr1qxsju3y0mlke2h6h2g6qgnq4r3jstngtyjxs0nnp5zrv28zv8p5rgzruxyjz33j9k23pffta8z639e2snjdd4vcetfqsn4vwr3` |
| **XRP** | XRP Ledger | `rpvijHi2nVY9WWAJhojsAX5tJmHdmLtFhq` |

Each address also has a scan-to-donate **QR code** in the app under **Support** (and they're listed in [`docs/DONATIONS.md`](docs/DONATIONS.md)). *Always copy the full address and double-check the first and last characters; crypto transactions are irreversible, and only ever send a coin to its own network.*

**Can't or would rather not?** Also genuinely valued: **⭐ star this repo**, file a good bug report, share a strap log, test on hardware you own, or just tell another WHOOP user. That moves NOOP forward too.

---

## Download

Pre-built apps you can run right now:

| Platform | Build | Notes |
|---|---|---|
| **macOS** | `NOOP.app` (see [Releases](../../releases)) | Apple Silicon + Intel. Drag to Applications. Not notarized — see **First launch on macOS** below. |
| **Android** | `NOOP-full.apk` (see [Releases](../../releases)) | The full app. `minSdk 26` (Android 8+). Sideload — enable "install unknown apps". |
| **Android (demo)** | `NOOP-demo.apk` | Preloaded with sample data so you can explore every screen with no strap. Installs alongside the full app. |
| **iOS** | Build from source — see [PR #42](../../pull/42) | An experimental community port (app + widgets + HealthKit). **Not distributed as a download:** iOS has no anonymous install path — the App Store and TestFlight both require a real Apple Developer identity — so it's build-it-yourself in Xcode, not officially maintained. |

> **First launch on macOS.** NOOP is **not notarized** by Apple — notarization needs a paid Apple
> Developer ID tied to a real identity, which doesn't fit an anonymous, free project. The app *is*
> sandboxed and ad-hoc code-signed, and the full source is here to inspect. Because it isn't notarized,
> macOS Gatekeeper blocks it on first open (you may see *"damaged"* or *"unverified developer"* — that's
> the download quarantine flag, not real damage). To open it, do one of these **once**:
>
> - **Terminal (most reliable):** drag `NOOP.app` to Applications, then run
>   `xattr -dr com.apple.quarantine /Applications/NOOP.app` and open NOOP normally.
> - **No Terminal:** double-click NOOP (it'll be blocked), then open **System Settings → Privacy &
>   Security**, scroll to the bottom, and click **"Open Anyway"** next to NOOP. (On macOS 14 and
>   earlier you can also right-click the app → **Open**.)
>
> Prefer to avoid this entirely? Build from source — see [Quickstart](#quickstart-macos).

Prefer to build it yourself? See [`docs/BUILD.md`](docs/BUILD.md).

Everything runs **offline**. The only feature that ever uses the network is the optional **AI Coach**, and only with your own API key.

---

NOOP is a standalone, fully **offline** companion app for WHOOP straps (4.0 and
5.0). It pairs directly with the strap over Bluetooth, stores everything on your
own device in SQLite, imports your existing WHOOP and Apple Health history, and
computes recovery, strain, HRV, and sleep **locally**, with no WHOOP account and
no WHOOP cloud.

It is built on prior community reverse-engineering work and exists for one
reason: to let someone who owns a WHOOP strap read **their own biometric data**
from **their own device**, on a machine **they** control.

> **Not affiliated with WHOOP.** NOOP is an independent, unofficial
> interoperability project. It is not affiliated with, endorsed by, or connected
> to WHOOP, Inc. "WHOOP" is used only to identify the hardware NOOP talks to. Use
> it only with a device you own, and not in breach of any agreement that applies
> to you. **NOOP is not a medical device**; every derived metric is an
> approximation, not clinical data. See [`DISCLAIMER.md`](DISCLAIMER.md).

---

## Contents

- [Why NOOP](#why-noop)
- [Features](#features)
- [Platform status](#platform-status)
- [Architecture](#architecture)
- [Quickstart (macOS)](#quickstart-macos)
- [How your data flows](#how-your-data-flows)
- [Privacy](#privacy)
- [Attribution](#attribution)
- [Support (optional)](#support-optional)
- [Disclaimer](#disclaimer)
- [License](#license)
- [Docs](#docs)

---

## Why NOOP

You bought the strap. The biometric stream it produces is yours. NOOP is built on
that premise:

- **Own your data.** NOOP reads heart rate, R-R intervals, SpO₂, skin temperature,
  respiration, accelerometer/gravity, battery, and event data straight off the
  strap over Bluetooth and writes it to a local SQLite database. Nothing is
  uploaded anywhere.
- **Account-free and local.** NOOP never logs into a WHOOP account and never hits
  a WHOOP server. It does not bypass any login, paywall, or DRM; it simply talks to
  a device you own and reads data you generated.
- **Bring your history.** Already have years of data in the official app or in
  Apple Health? Import the WHOOP CSV export and/or your Apple Health `export.xml`
  once, and it's permanently on your machine.
- **Transparent math.** Recovery, strain, HRV, and sleep are recomputed on-device
  from documented, citable methods (Task Force 1996 HRV, Karvonen %HRR, Edwards /
  Banister TRIMP, Tanaka HRmax, and so on). The algorithms are approximations of —
  not reproductions of — any proprietary model, and every analyzer file documents
  exactly what it does.

---

## Features

The macOS reference app organizes everything behind a single sidebar
(`Strand/App/RootView.swift`). Each item below is a real screen in
`Strand/Screens/`.

| Screen | What it does |
|---|---|
| **Today** (Control Center) | Home dashboard: recovery ring, a "today's synthesis" insight, a grid of stat tiles (recovery, strain, sleep, HRV, RHR, SpO₂, respiratory, steps, weight, calories) each with a 14-day sparkline, recent workouts, and a data-sources footer. |
| **Readiness** | An on-device "should you push today?" read that synthesizes established sports-science signals from your own history — HRV vs your baseline (Plews/Buchheit), resting-HR drift (Lamberts), sleeping respiratory-rate drift, training-load balance (acute:chronic workload ratio, Gabbett) and training monotony (Foster) — into a single headline (Primed / Balanced / Strained / Run down) with the drivers behind it. Pure local math, not medical advice. |
| **Live** | Real-time view of the connected strap — heart rate and frame stream as they arrive (~1 Hz). |
| **Breathe** | **HRV haptic breathing biofeedback.** The strap both *measures* HRV (R-R intervals) and *buzzes* its haptic motor, so NOOP paces your breath with felt cues (one buzz inhale, two exhale) and shows live HR + rolling RMSSD responding as the session deepens. Presets: Relax 4-6, Coherence 5.5, Box 4-4. |
| **Intervals** | **Silent haptic HIIT timer.** The strap buzzes every transition (triple-buzz into WORK, single into REST, 3-2-1 tick at phase ends, long buzz on finish) so you train hands-free. Falls back to a glanceable visual timer with no strap. |
| **Explore** (Metric Explorer) | Interrogate any single metric over time, built from the metric catalog (`Strand/Data/MetricCatalog.swift`). |
| **Compare** | Plot two metrics together / against each other over a shared timeline. |
| **Insights** | Behavioral and correlational insights derived from your own series. |
| **Sleep** | Sleep sessions with a hypnogram, stage breakdown, efficiency, resting HR, and HRV — computed by the on-device sleep stager. |
| **Trends** | Long-range trends across recovery, strain, sleep, and biometrics. |
| **Workouts** | Detected exercise sessions with strain and heart-rate detail. |
| **Health** | Biometric overview (HR, HRV, SpO₂, skin temperature, respiratory rate, etc.). |
| **Stress** | Day-level stress / autonomic load visualization. |
| **Apple Health** | Browse and reconcile data imported from your Apple Health export. |
| **Data Sources** | One-tap import of a WHOOP CSV export or an Apple Health export, plus live-strap status. "Bring your history in once, then it's yours." |
| **Notifications** | Configure local notifications and thresholds (`Strand/Data/NotificationSettingsStore.swift`). |
| **Automations** | Turn the strap's physical inputs and live biometrics into Mac actions — all on-device (see below). |
| **Coach** | An optional **AI Coach** you can ask about your data in plain language. It's the one feature that ever uses the network: off until you add your own OpenAI/Anthropic key, and it sends only a short text summary of recent metrics plus your question — never raw streams or identifiers. On the sandboxed macOS build it's blocked by the App Sandbox (no network entitlement); it works on Android. See [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md). |
| **Settings** | Profile, preferences, the in-app **What's new** changelog, and an opt-in **Experimental** section (WHOOP 5/MG protocol probes). |
| **Support** | Attribution + **optional** crypto donations. The whole app works without them. |

There is also a **menu-bar extra** (`Strand/MenuBar/MenuBarContent.swift`) with a
glanceable live HR readout and a compact popover, a first-run **onboarding wizard**
that sets expectations (independent/experimental, WHOOP 4.0 vs 5/MG, on-device only),
and an in-app **"What's new"** changelog shown after each update.

### Automations (on-device)

`Strand/Screens/AutomationsView.swift` + `Strand/System/MacActions.swift`:

- **Double-tap → Mac action.** Double-tap the strap to lock the Mac, buzz back to
  confirm, mark a moment, do nothing, or run any macOS **Shortcut** by name (via
  the `shortcuts://` URL scheme, so it's sandbox-friendly).
- **Wear & presence.** Lock the Mac (or run a Shortcut) the moment the strap
  leaves your wrist; run a Shortcut when it goes back on. *(macOS reserves true
  auto-**unlock** for Apple Watch — NOOP can lock, not unlock.)*
- **Haptic coaching.** HR-zone coaching and an experimental resting-stress nudge —
  the strap buzzes so you don't have to watch a screen.
- **Smart alarm.** Arms the strap's own **firmware** alarm to buzz at your wake
  time (still fires if the Mac is asleep or NOOP is closed), with an optional
  light-sleep wake window when the Mac stays awake and connected.

---

## Platform status

NOOP's logic lives in cross-platform Swift packages, and the same protocol,
storage, analytics, and scoring is ported to Kotlin on Android. Both apps pair
with the strap and **score recovery, strain and sleep on your own device** — no
import required.

| Platform | Status |
|---|---|
| **macOS** | ✅ Full app (`Strand/`, SwiftUI, macOS 13+). Pairs over BLE, offloads the strap's history, and scores recovery / strain / sleep on-device. The complete feature set above runs here. |
| **Android** | ✅ Full app (`android/`, Jetpack Compose, Android 8+). Pairs over BLE, persists and scores on-device, and imports WHOOP / Apple Health / Health Connect. Grab the APK from [Releases](../../releases). |
| **iOS** | 🧪 Experimental community port in [PR #42](../../pull/42) — app target + widgets + Live Activity + HealthKit, builds for the iOS simulator. **Build-from-source only, not officially maintained or distributed:** iOS has no anonymous distribution path (App Store and TestFlight both require a real Apple Developer identity), which is fundamentally at odds with this project staying anonymous. The shared packages already declare `.iOS(.v16)` and UI-framework code is guarded with `#if canImport(UIKit)` / `AppKit`. |

### Strap support

NOOP is an independent, **experimental** project — capable, but a work in progress.

| Strap | Status |
|---|---|
| **WHOOP 4.0** | ✅ The tested, supported path. Live HR, recovery, strain, sleep, history offload — the full experience. |
| **WHOOP 5.0 / MG** | 🧪 **Live heart rate works** (confirmed on real hardware). Pick "WHOOP 5.0 / MG" before connecting — and see the pairing note below, because you can't just scan for it. Deeper 5/MG metrics (recovery, strain, sleep) are still being reverse-engineered; there's an opt-in **Settings → Experimental** toggle for 5/MG owners who want to help map the protocol. |

> ### Pairing a WHOOP 5.0 / MG — read this first
>
> A WHOOP strap holds an encrypted Bluetooth **bond with only one device at a time**, and yours is
> normally bonded to the **official WHOOP app** on your phone. **You can't just scan for it in NOOP** —
> if the strap is still bonded to the WHOOP app, NOOP's pairing is refused and the strap log shows
> *"Encryption is insufficient"* / *"bond refused."* (Live **heart rate** is the exception — it rides the
> standard Bluetooth heart-rate profile, so it streams without a bond. But pairing — needed for the
> deeper features — does not.)
>
> **To pair properly:**
> 1. **Close the official WHOOP app** on your phone (fully quit it, or turn that phone's Bluetooth off) so
>    it isn't holding the bond.
> 2. **Put the strap in pairing mode** — the LEDs flash blue.
> 3. In NOOP: **Live → choose "WHOOP 5.0 / MG" → Scan & Connect.** Success looks like
>    *"CLIENT_HELLO acked — link established"* in the strap log (not *"bond refused"*). It can take a
>    couple of attempts.
>
> Bonding to NOOP may take the strap's bond away from the WHOOP app, so the official app might need to
> re-pair afterwards. This is the **hardest part of 5/MG support** — if it refuses, you're almost
> certainly still bonded to the WHOOP app; free the strap and retry.

The app always tells you what's live now versus still building, both in onboarding and on each screen.

### What to expect when you start

NOOP computes your scores on your own device, so like any recovery wearable it
needs a little data before everything fills in:

- **Live heart rate** shows the moment the strap connects.
- **Strain and sleep** appear after you've worn it and synced — the strap's last
  ~14 days offload automatically over the first few minutes.
- **Recovery** needs a few nights for the app to learn your personal baseline,
  then sharpens each night. WHOOP makes you wait for the same reason.
- **In a hurry?** Import your WHOOP export in Data Sources and your full history
  fills in about a minute.

---

## Architecture

The repository is split into platform-pure Swift packages plus a macOS app target.
All packages declare both `.iOS(.v16)` and `.macOS(.v13)`; framework-specific UI is
guarded with `#if canImport(UIKit)` / `#if canImport(AppKit)`.

```
Strand/                  macOS SwiftUI reference app (this is what you build)
Packages/
  WhoopProtocol/         BLE frame parsing, CRC, command/event/packet decode
  WhoopStore/            GRDB/SQLite persistence (migrations, streams, caches)
  StrandAnalytics/       HRV / recovery / strain / sleep / correlation math
  StrandImport/          WHOOP CSV + Apple Health importers
  StrandDesign/          SwiftUI design system (palette, components, charts)
Tools/Backfill/          CLI tool for backfilling decoded data
Fixtures/                sample WHOOP export for tests
```

### `WhoopProtocol` — the reverse-engineering core

Platform-pure (no CoreBluetooth import) so it runs in tests and CLI tools
unchanged. It decodes the on-wire frame format for both strap generations:

```swift
public enum DeviceFamily: String, Sendable, CaseIterable {
    case whoop4   // CRC8 (poly 0x07) header check; service 61080001-…
    case whoop5   // CRC16-Modbus header check, "puffin" packet types; service fd4b0001-…
}
```

Decoding is schema-driven (`Resources/whoop_protocol.json`) and includes CRC8,
CRC16-Modbus, and zlib CRC-32 implementations, frame framing, value
interpretation, and historical-stream reassembly. The app layer (`Strand/BLE/`,
`Strand/Collect/`) wraps these UUID *strings* in `CBUUID` and handles bonding,
offload, and live notifications.

### `WhoopStore` — local SQLite via GRDB

Everything is stored on-device in SQLite (using
[GRDB.swift](https://github.com/groue/GRDB.swift)). The schema is a versioned
migrator (`Database.swift`, currently through `v9`). Examples of decoded-stream
tables created in `v1`–`v3`:

```sql
CREATE TABLE hrSample      (deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY(deviceId, ts));
CREATE TABLE rrInterval    (deviceId TEXT, ts INTEGER, rrMs INTEGER, PRIMARY KEY(deviceId, ts, rrMs));
CREATE TABLE spo2Sample    (deviceId TEXT, ts INTEGER, red INTEGER, ir INTEGER, PRIMARY KEY(deviceId, ts));
CREATE TABLE skinTempSample(deviceId TEXT, ts INTEGER, raw INTEGER, PRIMARY KEY(deviceId, ts));
CREATE TABLE respSample    (deviceId TEXT, ts INTEGER, raw INTEGER, PRIMARY KEY(deviceId, ts));
```

Later migrations add server-derived metric caches (`sleepSession`, `dailyMetric`),
cursors, a raw frame outbox, and more.

### `StrandAnalytics` — transparent, on-device math

Pure, database-free analyzers. Each is documented and grounded in published
methods (and is explicitly an approximation, not a reproduction of any proprietary
model):

| File | Computes |
|---|---|
| `HRVAnalyzer.swift` | RMSSD + SDNN from R-R intervals (Task Force 1996), with range + Malik ectopic filtering. |
| `RecoveryScorer.swift` | A 0–100 recovery score: HRV-dominant z-score + logistic composite vs personal baselines. |
| `StrainScorer.swift` | A 0–21 logarithmic strain scale from %HRR (Karvonen) and Edwards / Banister TRIMP. |
| `SleepStager.swift` | Sleep/wake detection + approximate 4-class staging from cardiorespiratory + gravity features. |
| `CorrelationEngine.swift` | Pearson r, OLS regression, day-aligned and lagged correlations between two series. |
| `WorkoutDetector.swift`, `Baselines.swift`, `BehaviorInsights.swift`, `AnalyticsEngine.swift` | Workout detection, rolling baselines, behavioral insights, and the per-day orchestrator. |

### `StrandImport` — bring your own history

- **WHOOP CSV export** (`WhoopExportImporter.swift`): header-name-driven, tolerant
  parser for `physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`, and
  `journal_entries.csv`, from a folder or `.zip`. The same schema covers WHOOP 4 /
  5 / MG.
- **Apple Health export** (`AppleHealthImporter.swift`): a **streaming** SAX parser
  (`XMLParser`) for `export.xml` (which can exceed 1 GB), with correlation-dedupe,
  unit normalization (e.g. SpO₂ fraction → %), and sleep-stage mapping.

### `StrandDesign` — the SwiftUI design system

Palette, typography, motion, and reusable components/charts (`RecoveryRing`,
`StrainGauge`, `Hypnogram`, `Sparkline`, `TrendChart`, `YearHeatStrip`,
`StrandCard`, `StatePill`, …) — no external UI dependencies.

---

## Quickstart (macOS)

**Requirements:** macOS 13+, Xcode 15+ (Swift 5.9), and a Mac with Bluetooth. To
pair live, you need your own WHOOP strap; to just explore, you can import a CSV /
Apple Health export instead.

The Xcode project is generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
# 1. Clone
git clone <your-fork-url> NOOP
cd NOOP

# 2. (Re)generate the Xcode project from project.yml
brew install xcodegen   # if you don't have it
xcodegen generate

# 3. Open and run
open Strand.xcodeproj
# Select the "Strand" scheme → Run (⌘R). The built app is named NOOP.
```

Notes:

- Bundle id `com.noopapp.noop`, product name **NOOP**, sandboxed with the
  Bluetooth and user-selected-files entitlements.
- Swift Package Manager resolves the only third-party dependencies automatically:
  **GRDB.swift** (SQLite) and **ZIPFoundation** (export unzip).
- Run the tests from Xcode (the `StrandTests` target + each package's test target),
  or per-package with `swift test` inside `Packages/<Name>/`.

To explore without an Xcode project, the packages build on their own:

```bash
cd Packages/WhoopProtocol && swift build && swift test
```

---

## How your data flows

```
WHOOP strap ──BLE──▶ Strand/BLE + Strand/Collect ──▶ WhoopProtocol (decode)
                                                          │
WHOOP CSV  ─┐                                             ▼
Apple Health├─▶ StrandImport (parse) ───────────▶ WhoopStore (local SQLite)
 export.xml ─┘                                            │
                                                          ▼
                                            StrandAnalytics (recovery/strain/
                                            HRV/sleep, on-device)
                                                          │
                                                          ▼
                                          Strand (SwiftUI) + StrandDesign
```

Every arrow stays on your machine.

---

## Privacy

**Offline by design.** NOOP has no server, no telemetry, and no account. Your
strap data, imports, and computed metrics live in a local SQLite database on your
device and never leave it.

---

## Attribution

NOOP stands on community reverse-engineering and interoperability work. With
thanks:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE protocol; the `WhoopProtocol`
  and `WhoopStore` packages and the collection logic are adapted from this work.
- **`b-nnett/goose`** — the WHOOP 5.0 / MG BLE reverse-engineering (the `fd4b0001-…`
  service family, CRC16-Modbus header, and "puffin" packet types) that NOOP's
  WHOOP 5.0 path is ported from.
- **`groue/GRDB.swift`** — SQLite persistence.
- **`weichsel/ZIPFoundation`** — export unzipping.

NOOP contains no WHOOP proprietary code, firmware, logos, or assets, and performs
no DRM circumvention. Full detail in [`ATTRIBUTION.md`](ATTRIBUTION.md).

---

## Support (optional)

NOOP is free and always will be, and never gates a feature behind payment. If it's
useful to you and you want to help with the development and testing costs, optional
crypto donation addresses are shown on the in-app **Support** screen and listed in
[`docs/DONATIONS.md`](docs/DONATIONS.md). Donations are 100% optional and the app
never asks twice.

**Contact:** questions, feedback, and bug reports → [thenoopapp@gmail.com](mailto:thenoopapp@gmail.com)

---

## Disclaimer

NOOP is an independent, unofficial, non-commercial interoperability project. It is
**not affiliated with, endorsed by, or connected to WHOOP, Inc.** All references to
"WHOOP" are nominative — used only to identify the third-party hardware NOOP
interoperates with.

**NOOP is not a medical device.** Heart rate, HRV, recovery, strain, sleep stages,
SpO₂, respiratory rate, and skin temperature are **approximations** computed from
published methods. They are not clinically validated and are not medical advice. Do
not use them to diagnose, treat, or make health decisions — consult a qualified
professional.

Provided **as-is**, with **no warranty**, for **personal and educational use**. You
use it at your own risk. Read the full notice in [`DISCLAIMER.md`](DISCLAIMER.md).

---

## License

NOOP is **source-available** under the [PolyForm Noncommercial License 1.0.0](LICENSE):
**free for personal and other non-commercial use** — read it, run it, fork it, and
contribute. Commercial use is not granted by this license. (PolyForm Noncommercial is
a proper software license with patent terms; it is deliberately *not* an OSI
"open-source" licence, because that would permit the commercial use this project's
non-commercial nature rules out.)

The license covers NOOP's own original code and docs. Protocol facts (frame layouts,
command numbers, byte offsets) are uncopyrightable and free to reuse; bundled
dependencies keep their own licenses (GRDB.swift and ZIPFoundation are MIT — see
[`NOTICE`](NOTICE)). By opening a pull request you agree your contribution is licensed
under the same terms — see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

---

## Docs

- [`CHANGELOG.md`](CHANGELOG.md) — release history and what to expect (also shown in-app under **What's new**).
- [`DISCLAIMER.md`](DISCLAIMER.md) — trademark, interoperability, and medical/legal notice.
- [`ATTRIBUTION.md`](ATTRIBUTION.md) — full credits and licensing notes.
- [`docs/DONATIONS.md`](docs/DONATIONS.md) — optional donation addresses (also in-app under **Support**).
- [`project.yml`](project.yml) — XcodeGen project definition (source of `Strand.xcodeproj`).
