<!-- generated-by: gsd-doc-writer -->
# Testing

NOOP has two parallel test stacks — one for the Swift codebase (macOS app + Swift packages) and one for the Android app. Both run automatically in CI on every PR and push to `main`.

---

## Table of contents

- [Test structure overview](#test-structure-overview)
- [Running tests locally](#running-tests-locally)
  - [Swift packages (fastest loop)](#swift-packages-fastest-loop)
  - [macOS app tests](#macos-app-tests)
  - [Android unit tests](#android-unit-tests)
- [What each suite covers](#what-each-suite-covers)
  - [StrandTests (macOS app)](#strandtests-macos-app)
  - [WhoopProtocol package tests](#whoopprotocol-package-tests)
  - [WhoopStore package tests](#whoopstore-package-tests)
  - [StrandAnalytics package tests](#strandanalytics-package-tests)
  - [StrandImport package tests](#strandimport-package-tests)
  - [StrandDesign package tests](#stranddesign-package-tests)
  - [Android unit tests](#android-unit-tests-1)
- [CI test execution](#ci-test-execution)
- [Known pre-existing failures](#known-pre-existing-failures)
- [Adding new tests](#adding-new-tests)

---

## Test structure overview

| Layer | Framework | Location | How to run |
|---|---|---|---|
| macOS app integration | XCTest | `StrandTests/` | `xcodebuild … test` |
| WhoopProtocol (Swift package) | XCTest | `Packages/WhoopProtocol/Tests/WhoopProtocolTests/` | `swift test` |
| WhoopStore (Swift package) | XCTest | `Packages/WhoopStore/Tests/WhoopStoreTests/` | `swift test` |
| StrandAnalytics (Swift package) | XCTest | `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/` | `swift test` |
| StrandImport (Swift package) | XCTest | `Packages/StrandImport/Tests/StrandImportTests/` | `swift test` |
| StrandDesign (Swift package) | XCTest | `Packages/StrandDesign/Tests/StrandDesignTests/` | `swift test` |
| Android unit tests | JUnit 4 | `android/app/src/test/java/com/noop/` | `./gradlew testFullDebugUnitTest` |

The Swift packages are framework-free and test with plain `swift test` — no Xcode project, no strap, no Apple Developer account required. The macOS app tests (`StrandTests`) require XcodeGen to generate `Strand.xcodeproj` first.

---

## Running tests locally

### Swift packages (fastest loop)

Most contributions live in one package. Test it in isolation before running the full app suite:

```bash
cd Packages/WhoopProtocol  && swift build && swift test
cd Packages/WhoopStore     && swift build && swift test
cd Packages/StrandAnalytics && swift build && swift test
cd Packages/StrandImport   && swift build && swift test
cd Packages/StrandDesign   && swift build && swift test
```

The pure packages (`WhoopProtocol`, `StrandAnalytics`) also build and test on Linux with a standard Swift toolchain:

```bash
# On Linux — no Apple frameworks needed
cd Packages/WhoopProtocol && swift build && swift test
```

### macOS app tests

The Xcode project is generated from `project.yml`, not committed. Regenerate it before running tests, then whenever `project.yml`, `Strand/`, `StrandTests/`, or any `Packages/` file changes:

```bash
# Generate the project (required once, and after any structural file change)
xcodegen generate

# Build + test (no signing, no strap required)
xcodebuild \
  -project Strand.xcodeproj \
  -scheme Strand \
  -sdk macosx \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES \
  build test
```

To run from Xcode instead: open `Strand.xcodeproj`, select the `Strand` scheme targeting `My Mac`, and press Cmd+U.

### Android unit tests

```bash
cd android

# Run unit tests for the full-flavor debug build (what CI uses)
./gradlew testFullDebugUnitTest

# Run unit tests for all variants
./gradlew test

# Run a single test class
./gradlew testFullDebugUnitTest --tests "com.noop.protocol.FramingTest"
```

Android instrumentation tests (Espresso) are declared as dependencies but no instrumentation test sources exist in this project. All Android test coverage is through JVM unit tests under `src/test/`.

---

## What each suite covers

### StrandTests (macOS app)

**Location:** `StrandTests/`  
**File count:** 3 files  
**Run with:** `xcodebuild … test` (after `xcodegen generate`)

| File | What it tests |
|---|---|
| `StrandSmokeTests.swift` | Smoke test — confirms the app target links and runs |
| `RelativeAgoTests.swift` | `relativeAgo()` — the "History synced N ago" time label; mirrors the Android `RelativeAgoTest` case-for-case so both platforms produce identical labels |
| `WorkoutZonesTests.swift` | `WorkoutZones.percents()` / `WorkoutZones.summary()` — HR-zone JSON parsing for both macOS key shape (`{"z1":…}`) and Android key shape (`{"zone1":…}`); also tests duration-weighted zone aggregation across multiple sessions |

### WhoopProtocol package tests

**Location:** `Packages/WhoopProtocol/Tests/WhoopProtocolTests/`  
**Run with:** `cd Packages/WhoopProtocol && swift test`

| File | What it tests |
|---|---|
| `SmokeTests.swift` | `whoop_protocol.json` is bundled and loadable |
| `FramingTests.swift` | CRC-valid frame verification for WHOOP 4.0 (REALTIME_DATA, COMMAND_RESPONSE, etc.) using synthetic byte vectors cross-checked against Python |
| `DeviceFamilyFramingTests.swift` | CRC validation for both `DeviceFamily.whoop4` and `DeviceFamily.whoop5` envelopes; alarm frame parity goldens |
| `ReassemblerTests.swift` | Frame reassembly across split BLE notifications; family-aware reassembly; garbage-SOF recovery (the live-HR-freeze failure mode) |
| `StreamsTests.swift` | `extractStreams` / `extractHistoricalStreams` from decoded frames |
| `StreamsParityTests.swift` | Cross-platform parity: Swift and Kotlin produce identical stream output for the same captured bytes |
| `BiometricStreamsParityTests.swift` | Parity for SPO₂, skin temperature, respiration, and gravity streams |
| `HistoricalStreamsParityTests.swift` | Parity for historical (offload) stream decoding |
| `HistoricalMetaTests.swift` | `HISTORY_START` / `HISTORY_END` metadata classification |
| `HistoricalV24Tests.swift` | Historical v24 format decode |
| `Whoop4HistoricalV24HardwareTests.swift` | WHOOP 4.0 historical v24 format with real-hardware capture vectors |
| `Whoop5RealtimeTests.swift` | WHOOP 5.0/MG realtime frame decode (+4 byte offset vs 4.0) |
| `Whoop5HistoricalTests.swift` | WHOOP 5.0 historical decode |
| `Whoop5CommandResponseTests.swift` | WHOOP 5.0 command/response round-trips |
| `Whoop5EventTests.swift` | WHOOP 5.0 event frame decode |
| `Whoop5PpgWaveformTests.swift` | WHOOP 5.0 PPG waveform packet decode |
| `PuffinCaptureTests.swift` | Puffin (WHOOP 5/MG) frame capture and encode |
| `InterpreterEnvelopeTests.swift` | Schema-driven `ParsedFrame` field accessors |
| `SchemaTests.swift` | `whoop_protocol.json` schema loading and field coverage |
| `ValuesTests.swift` | Field value decoding (int, float, string, enum) |
| `PostHooksTests.swift` | Post-decode transformation hooks (e.g. SOC scaling: raw 875 → 87.5%) |
| `ParityTests.swift` | General cross-platform parity coverage |
| `VersionCheckTests.swift` | Protocol schema version checks |

### WhoopStore package tests

**Location:** `Packages/WhoopStore/Tests/WhoopStoreTests/`  
**Run with:** `cd Packages/WhoopStore && swift test`

> **Note:** The iOS CI step for WhoopStore runs with `continue-on-error: true` due to pre-existing
> failures unrelated to contributions. See [Known pre-existing failures](#known-pre-existing-failures).

| File | What it tests |
|---|---|
| `MigrationTests.swift` | Schema migrations apply cleanly; all expected tables exist; primary keys are correct; schema version is current (v9) |
| `InsertTests.swift` | `store.insert(streams:)` returns correct row counts; idempotent upsert by natural key |
| `ReadTests.swift` | Query helpers for HR, RR, events, and battery samples |
| `CursorTests.swift` | Backfill cursor read/write |
| `PruneTests.swift` | `prune(before:)` removes old raw batches |
| `RawOutboxTests.swift` | Raw batch enqueue and dequeue |
| `MetricsCacheTests.swift` | `DailyMetric` cache upsert and read |
| `MetricSeriesStoreTests.swift` | `metricSeries` upsert and retrieval |
| `ScaffoldTests.swift` | In-memory store scaffolding helpers |
| `BiometricStreamTests.swift` | SPO₂, skin temp, respiration, gravity sample insert/read |
| `LatestSampleTests.swift` | `latestHR()`, `latestBattery()` query helpers |
| `StepSampleTests.swift` | Step sample insert and retrieval |
| `JournalWorkoutAppleCacheTests.swift` | Workout cache from Apple Health journal |

### StrandAnalytics package tests

**Location:** `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/`  
**Run with:** `cd Packages/StrandAnalytics && swift test`

| File | What it tests |
|---|---|
| `AnalyticsEngineTests.swift` | Top-level `AnalyticsEngine.analyzeDay` integration |
| `RecoveryScorerTests.swift` | Recovery score: baseline Z-scores, clamping to 0–100, HRV/RHR/resp weighting |
| `StrainScorerTests.swift` | Strain score (Edwards/Banister TRIMP method) |
| `HRZonesTests.swift` | HR zone thresholds (Karvonen %HRR); zones function with age and maxHR override |
| `HRVAnalyzerTests.swift` | RMSSD and HRV baseline rolling window |
| `SleepStagerTests.swift` | Sleep staging from HR/RR/movement streams |
| `WorkoutDetectorTests.swift` | Workout detection and deduplication |
| `ComparisonEngineTests.swift` | Period comparison (current vs prior period) |
| `CorrelationEngineTests.swift` | Metric correlation analysis |
| `BaselinesTests.swift` | Baseline state machine (provisional → trusted thresholds, update cadence) |
| `BehaviorInsightsTests.swift` | Behavior pattern insights generation |
| `ReadinessEngineTests.swift` | Readiness scoring |
| `RecoveryCalibrationTests.swift` | Recovery calibration against user-labelled reference days |

### StrandImport package tests

**Location:** `Packages/StrandImport/Tests/StrandImportTests/`  
**Run with:** `cd Packages/StrandImport && swift test`

| File | What it tests |
|---|---|
| `WhoopExportImporterTests.swift` | WHOOP CSV export parsing using the fixture in `Fixtures/` |
| `AppleHealthImportift` | Apple Health `export.xml` SAX parsing |
| `AppleHealthAggregatorTests.swift` | Apple Health metric aggregation |
| `ImportCoordinatorTests.swift` | `ImportCoordinator.detectAndImport` routing logic |

The fixture file for import tests is bundled via `StrandImport`'s `Package.swift` resources. The `Fixtures/` directory at the repo root contains a sample WHOOP export used by these tests.

### StrandDesign package tests

**Location:** `Packages/StrandDesign/Tests/StrandDesignTests/`  
**Run with:** `cd Packages/StrandDesign && swift test`

Covers palette correctness and chart math utilities:

- `Color(hex:)` parsing
- `StrandPalette.recoveryColor()` and `strainColor()` gradient sampling, clamping, and endpoint accuracy
- `StrandPalette.recoveryState()` label bucketing (DEPLETED / LOW / MODERATE / PRIMED / PEAK)
- HR zone color mapping; sleep stage color mapping
- `ChartHoverMath.nearestIndex()` — evenly spaced and arbitrary x-coordinate variants
- `ChartTooltipPlacement.position()` — stays within bounds, flips below anchor when no room above
- `SleepInterval.duration` and `SleepStage.bandRank` ordering

### Android unit tests

**Location:** `android/app/src/test/java/com/noop/`  
**Framework:** JUnit 4.13.2  
**Run with:** `cd android && ./gradlew testFullDebugUnitTest`

Tests are organized by package, mirroring the production code structure:

| Package | Files | What is tested |
|---|---|---|
| `com.noop.protocol` | `FramingTest`, `CrcTest`, `Whoop5HistoricalDecodeTest`, `HistoricalFallbackTest`, `HistoricalStreamsClockCorrectionTest`, `BackfillCaptureJsonlTest`, `BackfillCaptureSummaryTest`, `AlarmPayloadTest` | BLE frame framing (WHOOP 4.0 and 5.0/MG), CRC-8 and CRC-16 Modbus, frame reassembly, historical decode, clock correction, alarm payloads — many tests use the same byte vectors as the Swift parity tests |
| `com.noop.analytics` | `AnalyticsTest`, `BaselineSeedingTest`, `DayCaloriesTest`, `ReadinessEngineTest`, `RespRateRsaTest`, `RouteMathTest`, `SkinTempAnalyticsTest`, `StepsAnalyticsTest`, `WorkoutSportTest` | Recovery/strain analytics, calorie estimation, readiness engine, route/GPS math, sensor analytics |
| `com.noop.ble` | `Whoop5OffloadTest` | WHOOP 5.0 historical offload state machine |
| `com.noop.ingest` | `WhoopCycleSeriesTest` | Data ingestion cycle series |
| `com.noop.location` | `TrackFilterTest` | GPS track filtering |
| `com.noop.notif` | `CallAlertPolicyTest`, `IllnessAlertPolicyTest`, `VoipCallClassifierTest` | Notification policy logic |
| `com.noop.ui` | `RelativeAgoTest`, `RecoveryCalibrationTest`, `SleepImportedFiguresTest`, `SleepStageSegmentsTest`, `StrapStatusDetailTest`, `WorkoutSourceLabelTest`, `WorkoutZonesTest` | UI helper functions; `WorkoutZonesTest` and `RelativeAgoTest` mirror the Swift equivalents case-for-case |
| `com.noop.update` | `UpdateCheckTest` | In-app update check logic |
| `com.noop.widget` | `PushGateTests` | Home screen widget gate policy |

---

## CI test execution

Three workflows run tests automatically:

### `macos.yml` — macOS CI

**Trigger:** PRs and pushes to `main` that touch `Strand/**`, `StrandTests/**`, `Packages/**`, or `project.yml`  
**Runner:** `macos-15`

Steps:
1. Install XcodeGen (verifies version 2.45.x)
2. `xcodegen generate`
3. `xcodebuild … build test` with `CODE_SIGNING_ALLOWED=NO` — builds `NOOP.app` and runs `StrandTests`
4. Uploads `NOOP.app` as a build artifact (retained 7 days)

### `ios.yml` — iOS CI (Swift packages)

**Trigger:** PRs and pushes to `main` that touch `Packages/**` or `Strand/**`  
**Runner:** `macos-15`, targeting `iPhone 16` simulator

Runs `xcodebuild test` for each package in turn:

| Step | Package | `continue-on-error` |
|---|---|---|
| Test WhoopProtocol | `Packages/WhoopProtocol` | No — failures block the PR |
| Test WhoopStore | `Packages/WhoopStore` | **Yes** — pre-existing failures (see below) |
| Test StrandAnalytics | `Packages/StrandAnalytics` | No |
| Test StrandDesign | `Packages/StrandDesign` | No |
| Test StrandImport | `Packages/StrandImport` | No |

All `.xcresult` bundles are uploaded as `noop-ios-test-results` (retained 7 days).

### `android.yml` — Android CI

**Trigger:** PRs and pushes to `main` that touch `android/**`  
**Runner:** `ubuntu-latest`

Steps:
1. Set up JDK 17 (Temurin)
2. Validate Gradle wrapper
3. `./gradlew assembleFullDebug`
4. `./gradlew testFullDebugUnitTest` — all JUnit tests under `src/test/`
5. Uploads the debug APK as `noop-full-debug` (retained 7 days)

---

## Known pre-existing failures

**WhoopStore iOS tests** (`Packages/WhoopStore/Tests/`): the iOS CI step runs with `continue-on-error: true` because WhoopStore has pre-existing test failures in the iOS Simulator context unrelated to GRDB behavior on macOS. The failures do not affect the macOS build-and-test step (which runs without `continue-on-error`) or the Android suite. PRs are not expected to fix these unless the PR specifically targets WhoopStore iOS compatibility.

---

## Adding new tests

### Swift packages

New package tests go in `Packages/<Name>/Tests/<Name>Tests/`. Each file imports XCTest and the package under test:

```swift
import XCTest
@testable import WhoopProtocol   // or WhoopStore, StrandAnalytics, etc.

final class MyNewTests: XCTestCase {
    func testSomething() {
        XCTAssertEqual(myFunction(), expectedValue)
    }
}
```

Run with `cd Packages/<Name> && swift test`. No registration step is needed — Swift Package Manager discovers all `XCTestCase` subclasses automatically.

**Guidelines:**
- Keep package tests pure. `WhoopProtocol`, `StrandAnalytics`, and `FrameRouter` are framework-free — avoid adding framework imports to their tests.
- For new decode logic, add a concrete byte vector test (generated independently, not just the code verifying itself).
- For new analytics, add a test with a known input/output pair and cite the method or the reference value.
- Cross-platform parity tests (Swift ↔ Android producing identical output from the same bytes) are highly valued. Match the case-for-case style of `RelativeAgoTests.swift` / `RelativeAgoTest.kt` and `WorkoutZonesTests.swift` / `WorkoutZonesTest.kt`.

### macOS app tests

New app tests go in `StrandTests/` and import `@testable import Strand`:

```swift
import XCTest
@testable import Strand

final class MyFeatureTests: XCTestCase {
    func testMyFeature() {
        // …
    }
}
```

After adding a new file, re-run `xcodegen generate` to register it in the Xcode project before running `xcodebuild … test`.

### Android unit tests

New Android tests go in `android/app/src/test/java/com/noop/<package>/` and follow the JUnit 4 pattern:

```kotlin
package com.noop.mypackage

import org.junit.Assert.assertEquals
import org.junit.Test

class MyFeatureTest {
    @Test fun myBehaviourDescription() {
        assertEquals(expected, myFunction())
    }
}
```

Test function names use camelCase descriptions with no leading `test` prefix (e.g., `underAMinuteIsJustNow()`, not `testUnderAMinuteIsJustNow()`). Run with `./gradlew testFullDebugUnitTest` from the `android/` directory.

**What belongs in Android unit tests:**
- Pure logic: protocol parsing, analytics, policy rules, formatting helpers
- Tests that run on the JVM without a device or emulator
- Cross-platform parity cases that mirror a Swift test case-for-case

Instrumentation tests (Espresso, Compose UI Testing) require a device or emulator. The project currently has no instrumentation test sources; add them under `android/app/src/androidTest/` if needed, but they will not run in CI without an emulator step.

### Schema migrations (WhoopStore)

When adding a new migration (`migrator.registerMigration("vN") { db in … }`), always add a corresponding test in `Packages/WhoopStore/Tests/WhoopStoreTests/MigrationTests.swift` that:
1. Confirms the migration applies cleanly on an in-memory store
2. Asserts the new table or column is present
3. Updates `WhoopStoreInfo.schemaVersion` to the new version number

See `MigrationTests.testV5AddsSyncedColumnToDecodedTables()` for the pattern.

---

*See [CONTRIBUTING.md](CONTRIBUTING.md) for the broader test philosophy, fixture conventions, and BLE safety rules.*
