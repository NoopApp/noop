# iOS Provisions & Port Plan

> **Experimental, build-from-source community port — not an officially distributed app.** This
> document describes an **experimental, build-it-yourself iOS port of NOOP** ([PR #42](../../../pull/42)),
> **not** an officially maintained or distributed product. There is no download: iOS has no
> anonymous distribution path — the App Store and TestFlight both require a real Apple Developer
> identity — so distribution is impossible while NOOP stays anonymous. Build it yourself in Xcode if
> you want to run it. (macOS remains the reference implementation; Android ships as a full app.)

This document describes how NOOP — a standalone, fully offline companion app for
WHOOP straps — is positioned for iOS, what already works, and the concrete plan
for a native iOS app target.

> **Not affiliated with WHOOP.** NOOP is an independent, unofficial project. It is
> not affiliated with, endorsed by, or connected to WHOOP, Inc. "WHOOP" is used
> nominatively only to identify the hardware the app interoperates with — your own
> device and your own data. NOOP performs no DRM circumvention and ships no WHOOP
> proprietary code, firmware, or assets. **NOOP is not a medical device;** all
> metrics (HR, HRV, recovery, strain, sleep, SpO₂, temperature) are approximations
> and not clinically validated.

The reverse-engineering that makes any of this possible is built on prior
community work: the WHOOP 4.0 protocol from **`johnmiddleton12/my-whoop`** and
the WHOOP 5.0 / MG protocol from **`b-nnett/goose`**. See [`../ATTRIBUTION.md`](../ATTRIBUTION.md).

---

## TL;DR

- **All five shared packages already build for iOS.** Every `Package.swift` declares
  `.iOS(.v16)` alongside `.macOS(.v13)`, and the only UI-framework-specific code is
  guarded with `#if canImport(UIKit)` / `#if canImport(AppKit)`.
- The work to ship on iOS is **app-layer only**: a new iOS app target that reuses
  `WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, `StrandImport`, and `StrandDesign`
  unchanged, plus iOS variants of the handful of macOS-only app-layer services
  (menu bar, screen lock, Shortcuts, pasteboard).
- **CoreBluetooth is fully available on iOS** and the BLE engine is already written
  with iOS background collection in mind (state restoration hooks exist).
- **HealthKit is available on iOS** (it is not on macOS), so iOS can do *two-way*
  Apple Health: read live, and write NOOP-computed metrics back. On macOS, Apple
  Health is import-only via the static `export.xml` / `export.zip` file.

---

## Current platform support in the packages

The shared logic lives in five SwiftPM packages under [`Packages/`](../Packages/). Each
declares both platforms in its manifest:

| Package | Role | Platforms declared | iOS-relevant notes |
|---|---|---|---|
| `WhoopProtocol` | BLE frame parsing, CRC, command/event/packet decode — the reverse-engineering core | `.iOS(.v16)`, `.macOS(.v13)` | Platform-pure. **Never imports CoreBluetooth or any UI framework.** Exposes GATT UUIDs as plain *strings* (see `DeviceFamily.swift`); the app wraps them in `CBUUID`. |
| `WhoopStore` | GRDB/SQLite persistence (migrations, decoded streams, metric caches) | `.iOS(.v16)`, `.macOS(.v13)` | Depends on `WhoopProtocol` + GRDB.swift `6.0.0+`. GRDB supports iOS first-class. |
| `StrandAnalytics` | HRV / recovery / strain / sleep / correlation math | `.macOS(.v13)`, `.iOS(.v16)` | Pure computation; no platform APIs. |
| `StrandImport` | WHOOP CSV + Apple Health (`export.xml`, streaming) importers | `.macOS(.v13)`, `.iOS(.v16)` | Depends on `WhoopProtocol`, `WhoopStore`, ZIPFoundation `0.9.0+`. Uses a streaming `XMLParser` (SAX), so it stays memory-bounded even on iOS for multi-hundred-MB exports. |
| `StrandDesign` | SwiftUI design system (palette, components, charts) | `.macOS(.v13)`, `.iOS(.v16)` | The one package with a platform branch: `Palette.swift` resolves `Color` → sRGB components via `NSColor` under `#if canImport(AppKit)` and `UIColor` under `#elseif canImport(UIKit)`. |

> **Verify:** see each `Packages/<Name>/Package.swift`. The `platforms:` array carries
> both `.iOS(.v16)` and `.macOS(.v13)` in all five.

### The one cross-platform shim that already exists

`StrandDesign/Sources/StrandDesign/Palette.swift` is the template for how UI-framework
differences are handled across the codebase:

```swift
extension Color {
    /// Resolve to sRGB RGBA components in 0...1.
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}
```

Because the design system already compiles against UIKit, the SwiftUI components,
charts, and palette render on iOS as-is.

---

## The macOS app today (the reference implementation)

The macOS app target lives in [`Strand/`](../Strand/). It is the reference
implementation; Android ships as a full app (`android/`), and the iOS app is an
experimental, build-from-source community port ([PR #42](../../../pull/42)). The macOS app composes
the packages like this:

- `Strand/App/StrandApp.swift` — the `@main` SwiftUI `App`. Declares a `WindowGroup`
  and a `MenuBarExtra` scene.
- `Strand/App/AppModel.swift` — root `@MainActor` state object. Owns `LiveState`,
  the `BLEManager`, the `Repository` read-model, the `ProfileStore`, and the
  `BehaviorStore`.
- `Strand/BLE/BLEManager.swift` — the CoreBluetooth engine.
- `Strand/Collect/` — the collector, backfiller, clock-correlation, and store paths.
- `Strand/Data/` — `Repository`, importers, and settings stores.
- `Strand/Screens/` — the SwiftUI screens (Today, Trends, Sleep, Workouts, etc.).
- `Strand/System/MacActions.swift` — **macOS-only side effects** (screen lock, Shortcuts).
- `Strand/MenuBar/MenuBarContent.swift` — **macOS-only** menu-bar extra.

Most of `Strand/` is plain SwiftUI + the shared packages and would move to iOS
unchanged or near-unchanged. The macOS-specific pieces are enumerated below.

The on-device database path is resolved in `Strand/Collect/StorePaths.swift`:

```swift
enum StorePaths {
    /// `<AppSupport>/OpenWhoop/whoop.sqlite`, creating the directory if needed.
    static func defaultDatabasePath() throws -> String {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("whoop.sqlite").path
    }
}
```

`FileManager.url(for: .applicationSupportDirectory, …)` is valid on iOS too, so this
helper works unchanged inside the iOS sandbox container. The `WhoopStore` actor opens
the database with WAL journaling and a 5-second busy timeout (`WhoopStore.swift`),
both fully supported on iOS.

---

## CoreBluetooth on iOS

The BLE engine (`Strand/BLE/BLEManager.swift`) uses **CoreBluetooth**, which is the
same framework on iOS and macOS. The strap interaction — scan by service → connect →
discover → **bond** (one confirmed write) → subscribe → reassemble fragmented frames →
route — is identical across platforms.

The engine already discovers the WHOOP 4.0 custom service and characteristics, plus
the standard Heart Rate (`180D` / `2A37`) and Battery (`180F` / `2A19`) services. The
WHOOP 5.0 / MG service family (`fd4b0001-…`, CRC16-Modbus header, the puffin packet
types) is modeled in `WhoopProtocol/DeviceFamily.swift` and exposed as UUID strings
the app wraps in `CBUUID`.

### Background BLE — what's already wired

The engine was written anticipating iOS background collection. `BLEManager` already
implements **CoreBluetooth state restoration**:

```swift
static let restoreID = "com.openwhoop.ble.central"

public func centralManager(_ central: CBCentralManager,
                           willRestoreState dict: [String: Any]) {
    guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
          let p = peripherals.first else { … }
    self.peripheral = p
    self.restoredPeripheral = p
    p.delegate = self
    // Collection only runs post-bond, so a restored link was already bonded; seed flags.
    state.bonded = true
    didBond = true
    …
}
```

When iOS relaunches the app into the background to deliver a BLE event, it calls
`willRestoreState` with the previously-connected peripheral. The engine stores it in
`restoredPeripheral` and, on the next `centralManagerDidUpdateState` `.poweredOn`,
reconnects that exact peripheral instead of starting a fresh scan — no user
interaction required.

> The macOS init deliberately **does not** pass the restoration identifier — the
> source comments call state restoration "an iOS background feature." On macOS:
>
> ```swift
> // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
> central = CBCentralManager(delegate: self, queue: .main)
> ```

### Background BLE — what the iOS target must add

To make `willRestoreState` actually fire on iOS, the iOS target's `CBCentralManager`
must be created **with** the restoration identifier, and the app must declare the
Bluetooth background mode:

```swift
// iOS-only initializer
central = CBCentralManager(
    delegate: self,
    queue: .main,
    options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID]
)
```

| Requirement | iOS action |
|---|---|
| Background execution | `UIBackgroundModes` in `Info.plist` includes `bluetooth-central`. |
| State restoration | Pass `CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID` when constructing the central. `BLEManager.restoreID` already exists. |
| Usage description | `NSBluetoothAlwaysUsageDescription` (the macOS target already supplies a copy in its `Info.plist` — reuse and re-word for iOS). |
| Reconnect on relaunch | Already handled by `willRestoreState` + `centralManagerDidUpdateState`. |
| App Sandbox / entitlement | iOS does not use `com.apple.security.device.bluetooth` (that is a macOS App Sandbox entitlement); the iOS Bluetooth capability is granted via the usage-description prompt + background mode. |

The keep-alive, liveness watchdog, periodic backfill, and reconnect-on-disconnect
timers in `BLEManager` are platform-neutral `DispatchSource` timers. Note that iOS
suspends the app between BLE events, so these timers do **not** run continuously in the
background the way they do on a Mac that stays awake — on iOS, progress is driven by
the system waking the app for BLE traffic. The existing logic (rate-limited
`requestSync`, persisted `backfillLastAt` watermark) is already designed to resume
correctly across process relaunches, which is exactly the iOS background lifecycle.

> **Not available in the Simulator.** CoreBluetooth has no simulator support — the
> source notes "Cannot run in the simulator; verified manually on-device." iOS BLE
> work must be tested on a physical device paired with a real strap.

---

## App-layer items that need iOS variants

These are the only pieces of `Strand/` that are macOS-specific. Each needs an iOS
equivalent (or to be conditionally compiled out).

### 1. Menu bar → there is no menu bar on iOS

`Strand/MenuBar/MenuBarContent.swift` provides a `MenuBarExtra` (a glanceable
zone-tinted HR dot + a compact recovery/HR/battery popover), wired in
`StrandApp.swift`. **iOS has no menu bar.** The iOS equivalents:

- A **Home Screen widget** / **Lock Screen widget** (WidgetKit) showing recovery,
  live/last HR, and battery — the natural iOS analogue of the menu-bar glance.
- A **Live Activity** (ActivityKit) during an active workout or live HR session.
- The popover's content (`RecoveryRing`, `StatePill`, the stats row) is already
  built from `StrandDesign` components and can be reused inside the widget views.

### 2. Screen lock — macOS-only API

`Strand/System/MacActions.swift` locks the Mac by `dlopen`-ing
`login.framework` and calling `SACLockScreenImmediate`. **There is no iOS equivalent;**
a third-party app cannot lock an iPhone. On iOS the `lockScreen` action should be
hidden from the action picker (`MacActionKind`) or remapped (see Shortcuts below).

### 3. Strap double-tap / wrist-off actions — the "run a Shortcut" gap

On macOS, a strap **double-tap** (or a wrist-off trigger) runs a configurable action.
The action set is `MacActionKind` in `MacActions.swift`:

```swift
enum MacActionKind: String, Codable, CaseIterable, Identifiable {
    case none, lockScreen, buzzBack, markMoment, runShortcut
}
```

`AppModel.handleDoubleTap()` dispatches through `runMacAction(_:shortcut:)`. On macOS,
`runShortcut` opens the `shortcuts://run-shortcut?name=…` URL via `NSWorkspace`:

```swift
static func runShortcut(_ name: String) {
    …
    let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)")
    NSWorkspace.shared.open(url)
}
```

**The portable actions move to iOS directly:**

- `buzzBack` — sends a haptic command to the strap over BLE; purely `BLEManager`, no
  platform API. Works on iOS.
- `markMoment` — appends a timestamp to `moments` in `AppModel` and persists to
  `UserDefaults`. Works on iOS.
- `none` — trivially portable.

**The Shortcuts story differs on iOS** and deserves its own design:

- iOS **can** open `shortcuts://run-shortcut?name=…` via `UIApplication.shared.open(_:)`,
  but iOS will *foreground the Shortcuts app to run the shortcut* — it cannot silently
  run an arbitrary user Shortcut from the background the way a Mac can. This makes the
  "double-tap runs an arbitrary Shortcut while my phone is in my pocket" pattern
  unreliable on iOS.
- The robust iOS approach is to **publish App Intents** (the App Intents framework)
  from NOOP — e.g. "Mark a moment", "Start live HR", "Buzz strap", "Log recovery". The
  user then builds Shortcuts/Automations that call *NOOP's* intents, and NOOP also
  appears in Spotlight, Siri, and the Shortcuts gallery.
- For invoking *other* apps from NOOP, support **x-callback-url** style deep links
  (`x-callback-url` is the de-facto inter-app callback convention) and the standard
  `shortcuts://x-callback-url/run-shortcut?name=…&x-success=…` form so control can
  return to NOOP after the external shortcut completes.

> Net: replace the macOS `runShortcut(_:)` plumbing with (a) **App Intents exposed by
> NOOP** for inbound automation and (b) **x-callback-url / `shortcuts://` deep links**
> for outbound calls, and remove `lockScreen` from the iOS action set.

### 4. Pasteboard

`Strand/Screens/SupportView.swift` copies a string with `NSPasteboard.general`. The
iOS equivalent is `UIPasteboard.general.string = …`. This is a one-call swap; wrap it
in a tiny `#if os(iOS)` / `#if os(macOS)` helper (the same pattern `Palette.swift`
already uses) so the screen compiles on both.

### Summary of app-layer deltas

| macOS-only file/API | iOS replacement |
|---|---|
| `MenuBar/MenuBarContent.swift` (`MenuBarExtra`) | WidgetKit widget + Live Activity; reuse `StrandDesign` views |
| `MacActions.lockScreen()` (`login.framework`) | Not possible on iOS — hide/remap the action |
| `MacActions.runShortcut(_:)` via `NSWorkspace` | App Intents (inbound) + `UIApplication.open` / x-callback-url (outbound) |
| `NSPasteboard` (`SupportView.swift`) | `UIPasteboard` behind an `#if os` helper |
| `NSWorkspace`/`NSImage` app icons in `NotificationSettingsStore.swift` | iOS has no per-app launch icons; replace with iOS notification settings UI |
| `CBCentralManager(delegate:queue:)` | `CBCentralManager(delegate:queue:options:[…RestoreIdentifierKey…])` + `bluetooth-central` background mode |

---

## HealthKit: two-way Apple Health is possible on iOS

This is the biggest *additive* opportunity on iOS.

- **macOS has no HealthKit.** The Mac app therefore consumes Apple Health **one way**,
  by importing the user's exported archive. `StrandImport/AppleHealthImporter.swift`
  stream-parses `export.xml` (optionally inside `export.zip`) with a SAX
  `XMLParser`/`XMLParserDelegate` — never a DOM, because the file can exceed 1 GB. It
  filters to the relevant `Record` types (HeartRate, RestingHeartRate,
  HeartRateVariabilitySDNN, OxygenSaturation, BodyTemperature, RespiratoryRate,
  SleepAnalysis, body-composition, etc.), de-dupes records that appear both top-level
  and nested in a `<Correlation>`, and normalizes units (e.g. `OxygenSaturation` 0–1 →
  percent).
- **iOS has HealthKit**, so the iOS target can do far more than parse a static export:

| Direction | iOS capability |
|---|---|
| **Read** | Query HealthKit live (`HKHealthStore`, `HKSampleQuery`, anchored/observer queries) for HR, RHR, HRV SDNN, SpO₂, wrist/body temperature, respiratory rate, sleep stages, workouts, body composition — the same types `relevantTypes` already enumerates in `AppleHealthImporter`. No manual export needed. |
| **Write** | Write NOOP-computed values back into Apple Health: HR / HRV / SpO₂ / temperature samples decoded from the strap, sleep analysis from `StrandAnalytics.SleepStager`, and workouts from `WorkoutDetector` — so NOOP data shows up across the user's Health ecosystem. |
| **Background delivery** | `HKObserverQuery` + `enableBackgroundDelivery` to keep the on-device store in sync without opening the app. |

Because `AppleHealthImporter` already defines the canonical type set, units, and
`SleepStage` mapping, an iOS `HealthKitImporter` can map `HKSample` objects onto the
**same** `StrandImport` models and feed the identical ingest path into `WhoopStore` —
the static-export importer and the live HealthKit importer converge on one schema.

> **Entitlement/Info.plist on iOS:** add the **HealthKit** capability and supply
> `NSHealthShareUsageDescription` (read) and `NSHealthUpdateUsageDescription` (write).
> Keep both directions strictly opt-in and on-device — consistent with NOOP's
> offline, no-cloud stance.

---

## Concrete iOS target structure

The recommended layout keeps the five packages untouched and adds a sibling iOS app
target. The bulk of `Strand/`'s SwiftUI screens move into a shared app layer; only the
platform-specific services are duplicated per OS.

```
Strand/                      # existing macOS app target (reference)
StrandiOS/                   # NEW iOS app target
├── App/
│   ├── StrandiOSApp.swift          # @main; WindowGroup only (no MenuBarExtra)
│   └── AppModel+iOS.swift          # iOS BLE options, HealthKit wiring
├── BLE/
│   └── BLEManager+iOS.swift        # central built WITH RestoreIdentifierKey
├── Health/
│   └── HealthKitBridge.swift       # two-way HealthKit (read + write)
├── System/
│   ├── iOSActions.swift            # UIPasteboard, App Intents, x-callback-url
│   └── NOOPAppIntents.swift        # App Intents exposed to Shortcuts/Siri
├── Widgets/
│   └── NOOPWidget.swift            # Home/Lock-Screen widget (menu-bar analogue)
└── Resources/
    └── Info.plist                  # UIBackgroundModes, Health + Bluetooth usage strings

Shared/                      # (optional) screens lifted out of Strand/Screens
└── …                        # TodayView, TrendsView, SleepView, … reused by both targets
```

The cleanest path is to move the platform-neutral SwiftUI screens
(`Strand/Screens/*` that don't touch `NS…`/`UI…` directly) into a shared location both
targets include, leaving each target with only its `@main` scene and its
platform-specific service shims.

### Package dependencies for the iOS target

The iOS app target depends on exactly the same five local packages the macOS target
already lists in [`project.yml`](../project.yml). Expressed as a SwiftPM target (e.g.
in an Xcode project generated by XcodeGen / Tuist, or a `Package.swift` app target):

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NOOPiOS",
    platforms: [.iOS(.v16)],
    dependencies: [
        .package(path: "Packages/WhoopProtocol"),
        .package(path: "Packages/WhoopStore"),
        .package(path: "Packages/StrandAnalytics"),
        .package(path: "Packages/StrandImport"),
        .package(path: "Packages/StrandDesign"),
    ],
    targets: [
        .executableTarget(
            name: "NOOPiOS",
            dependencies: [
                "WhoopProtocol",
                "WhoopStore",
                "StrandAnalytics",
                "StrandImport",
                "StrandDesign",
            ]
        ),
    ]
)
```

Equivalent XcodeGen stanza (mirroring the existing macOS `Strand` target in
`project.yml`, which already declares these five packages under `packages:` and lists
them under the target's `dependencies:`):

```yaml
targets:
  NOOPiOS:
    type: application
    platform: iOS
    deploymentTarget: "16.0"
    sources:
      - StrandiOS
      - Shared            # screens lifted from Strand/Screens, if shared
    info:
      path: StrandiOS/Resources/Info.plist
      properties:
        CFBundleName: NOOP
        CFBundleDisplayName: NOOP
        LSApplicationCategoryType: public.app-category.healthcare-fitness
        UIBackgroundModes:
          - bluetooth-central
        NSBluetoothAlwaysUsageDescription: >-
          NOOP connects directly to your WHOOP strap over Bluetooth to read heart rate,
          R-R intervals, battery, and sensor data locally on your iPhone. Nothing leaves
          your device.
        NSHealthShareUsageDescription: >-
          NOOP reads your own Apple Health data on-device to compute recovery, strain,
          and sleep. Nothing leaves your device.
        NSHealthUpdateUsageDescription: >-
          NOOP writes the metrics it computes from your strap back into Apple Health,
          on-device and only when you allow it.
    entitlements:
      path: StrandiOS/Resources/NOOP.entitlements
      properties:
        com.apple.developer.healthkit: true
        com.apple.developer.healthkit.background-delivery: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.noopapp.noop
        PRODUCT_NAME: NOOP
    dependencies:
      - package: WhoopProtocol
      - package: WhoopStore
      - package: StrandAnalytics
      - package: StrandImport
      - package: StrandDesign
```

> Note the entitlements differ by platform. macOS uses **App Sandbox** entitlements
> (`com.apple.security.app-sandbox`, `com.apple.security.device.bluetooth`,
> `com.apple.security.files.user-selected.read-write` — see
> `Strand/Resources/Strand.entitlements`). iOS instead uses the **HealthKit**
> entitlement plus the `bluetooth-central` background mode and the usage-description
> prompts; it does not use the macOS App Sandbox keys.

---

## Port checklist

- [ ] Add `StrandiOS` app target depending on the five existing packages (no package changes).
- [ ] Construct `CBCentralManager` with `CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID`.
- [ ] Add `UIBackgroundModes: [bluetooth-central]` and `NSBluetoothAlwaysUsageDescription`.
- [ ] Replace `MenuBarExtra` with a WidgetKit widget (+ optional Live Activity); reuse `StrandDesign` views.
- [ ] Build an iOS action layer: drop `lockScreen`, keep `buzzBack`/`markMoment`/`none`, expose **App Intents** for inbound automation and `shortcuts://` / x-callback-url for outbound.
- [ ] Swap `NSPasteboard` → `UIPasteboard` behind an `#if os` helper.
- [ ] Add a `HealthKitBridge` doing two-way Apple Health (read live + write NOOP metrics), mapping `HKSample`s onto the existing `StrandImport` models and `WhoopStore` ingest path. Add the HealthKit capability and the two Health usage strings.
- [ ] Verify BLE on a **physical iPhone** with a real strap (no Simulator BLE).

---

*NOOP keeps everything on-device. The iOS plan changes the front door (menu bar →
widgets, AppKit → UIKit, file import → HealthKit) but not the principle: your strap,
your data, no cloud.*
