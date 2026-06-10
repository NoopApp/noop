<!-- generated-by: gsd-doc-writer -->
# Development Guide

This guide covers the daily developer workflow for NOOP: environment setup, repository structure,
the iteration loop for each platform, how CI works, and where to put changes depending on what you
are modifying.

For build commands, signing, sandbox configuration, and pairing with a strap, see
[BUILD.md](BUILD.md). For contribution rules, BLE safety, and coding conventions, see
[CONTRIBUTING.md](CONTRIBUTING.md).

---

## Contents

- [Tools you need](#tools-you-need)
- [Repository structure](#repository-structure)
- [Daily dev loop](#daily-dev-loop)
  - [Swift packages (fastest)](#swift-packages-fastest)
  - [macOS app](#macos-app)
  - [Android app](#android-app)
- [Changing WhoopProtocol](#changing-whoopprotocol)
- [Changing the macOS app](#changing-the-macos-app)
- [Changing the Android app](#changing-the-android-app)
- [CI workflows](#ci-workflows)
- [Common pitfalls](#common-pitfalls)

---

## Tools you need

### macOS / Swift

| Tool | Version | How to install |
|------|---------|----------------|
| macOS | 13.0 (Ventura) or newer | Deployment target |
| Xcode | 26.x (Swift 6.3 toolchain) | Mac App Store or developer.apple.com |
| XcodeGen | 2.45+ | `brew install xcodegen` |

XcodeGen is required. The Xcode project (`Strand.xcodeproj`) is generated from `project.yml` and
is not committed to the repo. Without XcodeGen you cannot open or build the macOS app in Xcode.

The Swift packages (`Packages/`) build and test with plain `swift build` / `swift test` — no Xcode
project is needed for package-only work.

### Android / Kotlin

| Tool | Version | Notes |
|------|---------|-------|
| JDK | 17 (Temurin recommended) | `brew install --cask temurin@17` or via your SDK manager |
| Android Studio | Current stable | Bundles Android SDK, Gradle wrapper handles the rest |

The Gradle wrapper (`android/gradlew`) downloads the correct Gradle version automatically on first
run. You do not need to install Gradle manually.

---

## Repository structure

```
.
├── Strand/
│   ├── project.yml              # XcodeGen source of truth — edit this, not the .xcodeproj
│   ├── Strand.xcodeproj/        # Generated — do NOT hand-edit, gitignored
│   ├── Strand/                  # macOS SwiftUI app target (product: NOOP.app)
│   │   ├── App/                 # StrandApp, AppModel, RootView
│   │   ├── BLE/                 # CoreBluetooth, frame router, command set, live state
│   │   ├── Collect/             # Backfiller, Collector, clock correlation
│   │   ├── Data/                # Repository, importers, MetricCatalog, profile
│   │   ├── Screens/             # SwiftUI feature screens
│   │   ├── MenuBar/             # MenuBarExtra (glanceable live HR)
│   │   └── System/              # MacActions, ProjectInfo
│   ├── StrandTests/             # macOS app integration test suite
│   └── Packages/
│       ├── WhoopProtocol/       # BLE framing, CRC, decode — the reverse-engineering core
│       ├── WhoopStore/          # GRDB/SQLite persistence (schema, migrations, caches)
│       ├── StrandAnalytics/     # Recovery, strain, HRV, sleep math — pure functions
│       ├── StrandImport/        # WHOOP CSV + Apple Health importers
│       └── StrandDesign/        # SwiftUI design system (palette, components, charts)
├── android/                     # Android client — full Kotlin/Gradle app
│   ├── app/
│   │   ├── build.gradle.kts     # App module config (minSdk 26, compileSdk 34, Kotlin 17 JVM)
│   │   └── src/main/java/com/noop/
│   │       ├── ui/              # Compose screens, ViewModels, navigation
│   │       ├── ble/             # Android BLE client (WhoopBleClient)
│   │       └── data/            # Room database, repositories, importers
│   └── build.gradle.kts         # Root Gradle config
├── tools/
│   └── linux-capture/           # Python/bleak headless capture + whoop-decode CLI
├── Fixtures/                    # Sample WHOOP export used by package tests
└── .github/workflows/
    ├── macos.yml                # macOS CI: xcodegen + build + test
    ├── ios.yml                  # iOS CI: per-package tests on iPhone 16 simulator
    └── android.yml              # Android CI: assembleFullDebug + unit tests
```

### Where a change belongs

| What you are changing | Where it lives | Can test without a strap? |
|---|---|---|
| BLE frame parsing, CRC, packet/event types | `Packages/WhoopProtocol` | Yes — `swift test` + captured frames |
| SQLite schema, migrations, stream inserts | `Packages/WhoopStore` | Yes — `swift test` |
| Recovery, strain, HRV, sleep, workout math | `Packages/StrandAnalytics` | Yes — `swift test` |
| WHOOP CSV or Apple Health import logic | `Packages/StrandImport` | Yes — `swift test` + fixtures |
| Colors, fonts, components, charts | `Packages/StrandDesign` | Yes — `swift test` + Xcode Previews |
| CoreBluetooth, bonding, offload, live state | `Strand/BLE`, `Strand/Collect` | No — requires a strap for command behavior |
| macOS screens, sidebar, menu bar, automation | `Strand/Screens`, `Strand/App`, `Strand/MenuBar` | Yes — Xcode Previews |
| Android BLE, Compose UI, Room, importers | `android/` | Mostly — unit tests; instrumentation tests need a device |

The deeper into `Packages/` a change lives, the more it can be tested in isolation with `swift test`,
without a strap, without Xcode, and — for `WhoopProtocol` — even on Linux.

---

## Daily dev loop

### Swift packages (fastest)

For changes scoped to one package, build and test it in isolation. No Xcode project, no strap, no
signing needed:

```bash
cd /path/to/Strand/Packages/WhoopProtocol && swift build && swift test
cd /path/to/Strand/Packages/WhoopStore     && swift build && swift test
cd /path/to/Strand/Packages/StrandAnalytics && swift build && swift test
cd /path/to/Strand/Packages/StrandImport   && swift build && swift test
cd /path/to/Strand/Packages/StrandDesign   && swift build && swift test
```

This is the fastest feedback loop and the one CI uses for the iOS workflow. Run it before pushing
anything that touches a package.

### macOS app

The Xcode project is generated from `project.yml`. It is not committed. Always work from
`project.yml` as the source of truth.

```bash
# 1. Generate the Xcode project (needed after any project.yml change or file add/remove):
cd /path/to/Strand
xcodegen generate

# 2. Fast compile-and-type-check (no signing, no runnable bundle):
xcodebuild \
  -project Strand.xcodeproj \
  -scheme Strand \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

# 3. Run the test suite:
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test

# 4. Open in Xcode for interactive editing:
open Strand.xcodeproj
```

For a runnable `NOOP.app` (ad-hoc signed, no Apple ID required), see [BUILD.md](BUILD.md#3-the-ad-hoc-signed-noopapp).

### Android app

Open the `android/` directory in Android Studio and let Gradle sync, or use the Gradle wrapper
from the command line:

```bash
cd /path/to/android

# Build the debug APK (full flavour — real app, starts empty):
./gradlew assembleFullDebug

# Build the demo APK (preloaded with 120 days of synthetic data):
./gradlew assembleDemoDebug

# Run unit tests:
./gradlew testFullDebugUnitTest

# Install on a connected device:
./gradlew installFullDebug
```

The `full` flavour builds `NOOP` (`com.noop.whoop`); the `demo` flavour builds `NOOP Demo`
(`com.noop.whoop.demo`). They install side-by-side. An emulator cannot reach a physical strap for
BLE testing — use a real device.

---

## Changing WhoopProtocol

`Packages/WhoopProtocol` is the reverse-engineering core. It is platform-pure — no CoreBluetooth,
no AppKit, no UIKit — and it is the one package that also builds on Linux (the `whoop-decode` CLI
executable targets there).

### Typical change types

- **Adding or fixing a frame decode:** edit the schema-driven field mappings or the decode functions
  in `Sources/WhoopProtocol/`. Add a test case in `Tests/WhoopProtocolTests/` using a captured
  frame as input. Run `swift test` before pushing.
- **Updating the protocol JSON:** `Resources/whoop_protocol.json` is the machine-readable protocol
  schema. Changes here affect what fields `parseFrame` surfaces. Verify with a unit test.
- **Adding an event or packet type:** add the type to the appropriate enum, add a decode path, add
  a test. Keep the function pure — no side effects.
- **The `whoop-decode` CLI:** built as a separate executable target in `Package.swift`. It is used
  by `tools/linux-capture` for protocol reverse-engineering. Changes that break its interface also
  break the Linux capture workbench.

### Cross-platform contract

`WhoopProtocol` declares `[.iOS(.v16), .macOS(.v13)]`. Do not import `CoreBluetooth`, `AppKit`, or
`UIKit` anywhere in `Sources/WhoopProtocol/`. The package must compile on Linux with the open-source
Swift toolchain. CI enforces this via the iOS workflow (package tests on a simulator, no Mac
frameworks allowed in the package itself).

### After changing WhoopProtocol

```bash
cd Packages/WhoopProtocol
swift build && swift test
# If you also updated the whoop-decode CLI:
swift build --product whoop-decode
```

The macOS CI workflow will also run `xcodebuild build test` on the full app, which transitively
builds `WhoopProtocol`. The iOS CI workflow runs `WhoopProtocol-Package` tests on an iPhone 16
simulator.

---

## Changing the macOS app

The macOS app layer lives in `Strand/Strand/` (BLE, Collect, Data, Screens, App, MenuBar, System)
and `StrandTests/`. It wraps the pure packages and contains all CoreBluetooth code.

### `project.yml` is the source of truth

`Strand.xcodeproj` is generated by XcodeGen and is gitignored. When you:

- Add or remove a Swift source file
- Add or remove a resource (image, entitlement, plist)
- Change a build setting, scheme, or target dependency
- Add or remove a Swift package dependency

you must edit `project.yml` and re-run `xcodegen generate`. **Never hand-edit `Strand.xcodeproj`**
— the changes will be silently overwritten the next time anyone runs `xcodegen generate`.

```bash
# After any project.yml change or file add/remove:
cd /path/to/Strand
xcodegen generate
```

### Screens and UI

Every screen must use only `StrandDesign` tokens (palette, typography, components, spacing). See
the [design system section in CONTRIBUTING.md](CONTRIBUTING.md#the-design-system-is-the-law) for
the rule set and the component catalogue. Xcode Previews work without a strap and without running
the full app.

### BLE and Collect layer

Changes here affect real hardware on someone's wrist. Read the
[BLE safety contract in CONTRIBUTING.md](CONTRIBUTING.md#the-ble-safety-contract-read-this-before-touching-bluetooth)
before touching anything in `Strand/BLE/` or `Strand/Collect/`. Verify command behavior on a real strap.

### After changing the macOS app

```bash
xcodegen generate     # always, after file/project.yml changes
xcodebuild \
  -project Strand.xcodeproj \
  -scheme Strand \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test
```

---

## Changing the Android app

The Android app is a standalone Kotlin/Gradle module. It re-implements the same wire protocol
against Android's BLE stack. The protocol facts in
`Packages/WhoopProtocol/Resources/whoop_protocol.json` are language-agnostic reference material,
but the Android implementation is pure Kotlin — it does not call into the Swift packages.

### Product flavours

The build defines two flavours in `app/build.gradle.kts`:

| Flavour | App name | Application ID | Behaviour |
|---------|----------|----------------|-----------|
| `full` | NOOP | `com.noop.whoop` | Real app, starts empty, user pairs a strap or imports data |
| `demo` | NOOP Demo | `com.noop.whoop.demo` | Preloaded with 120 days of synthetic data, DEMO badge visible |

CI builds and tests the `full` flavour only (`assembleFullDebug`, `testFullDebugUnitTest`).

### Compile options

- `compileSdk 34`, `minSdk 26`, `targetSdk 34`
- `jvmTarget = "17"` (Kotlin compiler), `JavaVersion.VERSION_17` (Java compile options)
- Compose Compiler `1.5.14` (matched to Kotlin 1.9.24 — see the Compose-to-Kotlin compatibility
  table before bumping either)
- Minification is OFF for release builds (`isMinifyEnabled = false`) — see the comment in
  `build.gradle.kts` for why

### Release signing

`keystore.properties` is gitignored. When it is absent, release builds fall back to the debug key,
so a fresh clone can always build and install a release APK. See [BUILD.md](BUILD.md) for the
keystore setup recipe.

### After changing the Android app

```bash
cd android
./gradlew assembleFullDebug       # verify it compiles
./gradlew testFullDebugUnitTest   # run unit tests
```

---

## CI workflows

Three workflows live in `.github/workflows/`. Each triggers on PRs and pushes to `main`, scoped to
the paths it owns.

### macOS CI (`macos.yml`)

**Trigger:** PRs and pushes to `main` that touch `Strand/**`, `StrandTests/**`, `Packages/**`, or
`project.yml`. Also triggered manually via `workflow_dispatch`.

**Runner:** `macos-15`

**Steps:**
1. Install XcodeGen 2.45 via Homebrew (version is asserted — the step fails if the version does not match)
2. `xcodegen generate` — regenerate the Xcode project from `project.yml`
3. `xcodebuild build test` with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` — builds the full
   app and runs `StrandTests`
4. Upload `NOOP.app` as an artifact (retained 7 days)

A concurrency group (`macos-ci-${{ github.ref }}`) cancels in-progress runs on the same branch when
a newer commit arrives.

### iOS CI (`ios.yml`)

**Trigger:** PRs and pushes to `main` that touch `Packages/**` or `Strand/**`.

**Runner:** `macos-15`, iPhone 16 simulator (latest iOS SDK)

**Steps:** Each Swift package is tested separately on the iOS simulator:

| Step | Package | `continue-on-error` |
|------|---------|---------------------|
| Test WhoopProtocol | `WhoopProtocol-Package` | No |
| Test WhoopStore | `WhoopStore` | Yes |
| Test StrandAnalytics | `StrandAnalytics` | No |
| Test StrandDesign | `StrandDesign` | No |
| Test StrandImport | `StrandImport` | No |

`WhoopStore` runs with `continue-on-error: true` — GRDB's on-disk SQLite behavior can differ
between macOS and the iOS simulator; failures are reported but do not block the PR.

Test result bundles (`.xcresult`) are uploaded as artifacts (retained 7 days).

### Android CI (`android.yml`)

**Trigger:** PRs and pushes to `main` that touch `android/**`.

**Runner:** `ubuntu-latest`

**Steps:**
1. Set up JDK 17 (Temurin distribution)
2. Validate Gradle wrapper checksum
3. Set up Gradle (caching)
4. `./gradlew assembleFullDebug` — builds the full-flavour debug APK
5. `./gradlew testFullDebugUnitTest` — runs unit tests
6. Upload the APK as an artifact (retained 7 days, fails if APK is missing)

### Reading CI results

- A green checkmark on the PR means all three workflows passed for the files changed in that PR.
  A PR touching only `android/` will not trigger the macOS or iOS workflows.
- To see why a step failed, click the workflow run → the failing job → expand the failing step.
  For `xcodebuild` failures, look for `error:` lines in the build log. For Gradle failures, look for
  `> Task :…` failure lines.
- Artifacts (APK, NOOP.app, `.xcresult` bundles) are available in the workflow run's Artifacts panel
  for 7 days. Download them if you need to inspect the build output locally.

---

## Common pitfalls

### XcodeGen not re-run after file changes

If you add or remove a Swift file and do not run `xcodegen generate`, the Xcode project will not
include the new file and you will see "No such module" or missing-type errors in CI even though the
file exists on disk. Always re-run `xcodegen generate` after any structural change, and do not commit
`Strand.xcodeproj/` (it is gitignored).

```bash
cd /path/to/Strand
xcodegen generate
```

### Editing `Strand.xcodeproj` by hand

Any hand-edit to `Strand.xcodeproj` is overwritten the next time anyone runs `xcodegen generate`.
Always make project changes in `project.yml`.

### Adding a platform-specific framework to a Package

Adding `import CoreBluetooth`, `import AppKit`, or `import UIKit` to any file under `Packages/` will
break the iOS CI workflow (which compiles packages on the simulator, where `AppKit` is not available)
and may break the Linux build path for `WhoopProtocol`. Guard with `#if canImport(AppKit)` /
`#elseif canImport(UIKit)` or move the code to the app layer.

### Mismatched metric key

The `MetricCatalog` key, the key written by the importer/analyzer, and any raw SQL `WHERE key = …`
must all be identical strings. A mismatch produces a metric that silently shows no data. Verify the
key in all three places before pushing.

### Bumping Kotlin or Compose Compiler without checking compatibility

The Compose Compiler version (`kotlinCompilerExtensionVersion` in `app/build.gradle.kts`) must
match the Kotlin version according to the official Compose-to-Kotlin compatibility table. Bumping
one without the other produces a build failure with a compiler plugin version mismatch error. Check
the table at [developer.android.com](https://developer.android.com/jetpack/androidx/releases/compose-kotlin)
before bumping either.

### Running a BLE command not in `WhoopCommand`

`WhoopCommand` in `Strand/BLE/Commands.swift` is an intentionally curated subset of the strap's
command space. Destructive commands (reboot, DFU, ship-mode, force-trim, fuel-gauge reset) are
excluded. Do not add them. See the
[BLE safety contract](CONTRIBUTING.md#the-ble-safety-contract-read-this-before-touching-bluetooth).

### Testing BLE behavior on an emulator

The Android emulator cannot communicate with a physical WHOOP strap over Bluetooth. Use a real
Android device for any test that exercises the BLE path. macOS BLE tests also require a real strap
— the simulator has no CoreBluetooth equivalent.

### Signing errors in CI

Both macOS and Android CI run without signing credentials by design. macOS CI passes
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` to `xcodebuild`. Android CI relies on the
Gradle fallback to the debug keystore when `keystore.properties` is absent. Never commit signing
credentials or a `keystore.properties` file to the repo.
