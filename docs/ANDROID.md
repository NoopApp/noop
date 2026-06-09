# NOOP — Android Port Guide

NOOP is a standalone, fully **offline** companion app for WHOOP straps (4.0 and 5.0). It pairs
directly with the strap over Bluetooth Low Energy, stores everything on-device in SQLite, imports
WHOOP CSV exports and Apple Health exports, and computes recovery / strain / HRV / sleep locally.
There is no cloud, no account — the app talks only to **your own device** and
works only with **your own data**.

This document covers the **Android client** under [`android/`](../android). The macOS app is the
reference implementation; the Android app is a native re-implementation of the same wire protocol
and on-device data model, not a wrapper around the Swift code.

> **Not affiliated with WHOOP, and not a medical device.** "WHOOP" is used nominatively only to
> identify the hardware this software interoperates with. NOOP contains no WHOOP code, firmware, or
> assets, and performs no DRM circumvention — it talks only to the user's own device and the data it
> has already recorded. All outputs (HR, HRV, recovery, strain, sleep, SpO₂, temperature) are
> approximations and are **not** clinically validated. See [`../DISCLAIMER.md`](../DISCLAIMER.md)
> and [`../ATTRIBUTION.md`](../ATTRIBUTION.md).

> ### ⚠️ Status: faithful translation, **not yet compiled or device-tested**
>
> The Kotlin code in `android/` is a careful, line-by-line translation of the
> **hardware-verified** macOS protocol and analytics. It has **not** been built with Android
> Studio, run on an emulator, or tested against a real strap in this repository. Several files the
> manifest and build refer to are **still stubs or absent** (see
> [What exists vs. what is missing](#what-exists-vs-what-is-missing)). Treat the BLE connection
> layer in particular as **unproven on Android** until validated against a physical WHOOP 4.0/5.0.
> The [verification checklist](#verification-checklist) at the end is the gate before claiming the
> Android client works.

---

## Table of contents

- [Design intent](#design-intent)
- [Project structure](#project-structure)
- [What exists vs. what is missing](#what-exists-vs-what-is-missing)
- [Build prerequisites](#build-prerequisites)
- [Building](#building)
- [The protocol module (Kotlin port of `WhoopProtocol`)](#the-protocol-module-kotlin-port-of-whoopprotocol)
- [Android BLE layer](#android-ble-layer)
- [Storage with Room](#storage-with-room)
- [Analytics](#analytics)
- [Compose UI](#compose-ui)
- [Permissions and the no-internet posture](#permissions-and-the-no-internet-posture)
- [Donations](#donations)
- [Verification checklist](#verification-checklist)
- [Credits](#credits)

---

## Design intent

The Android app deliberately **does not** share a binary with the Swift packages. Instead it
re-implements the same observable behavior in idiomatic Kotlin:

| Swift package (reference) | Android counterpart | Status |
| --- | --- | --- |
| `WhoopProtocol` — BLE framing, CRC, command/event/packet decode | `com.noop.protocol` (Kotlin) | CRC ported; `parseFrame`/enums to do |
| `WhoopStore` — GRDB/SQLite persistence | `com.noop.data` (Room) | entities ported; DAOs/DB to do |
| `StrandAnalytics` — HRV / recovery / strain / sleep math | `com.noop.analytics` | RMSSD / zones / illness-watch ported |
| `StrandImport` — WHOOP CSV + Apple Health importers | _(planned)_ | not started |
| `StrandDesign` — SwiftUI design system | Jetpack Compose theme | theme stubs only |
| `Strand/` macOS app (CoreBluetooth + UI) | `com.noop.ui` + `com.noop.ble` (Compose + `BluetoothGatt`) | not started |

The single source of truth that **both** platforms must agree on is the protocol schema resource
`Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` (top-level keys
`version`, `enums`, `envelope`, `packets`) and the SQLite schema defined by the GRDB migrations in
`Packages/WhoopStore/Sources/WhoopStore/Database.swift`. Port against those files, not against
memory.

---

## Project structure

`android/` is a **single Gradle project** (Kotlin + Jetpack Compose), one application module named
`:app`:

```
android/
├── settings.gradle.kts          # rootProject.name = "NOOP"; include(":app")
├── build.gradle.kts             # root: declares AGP / Kotlin / KSP plugin versions (apply false)
├── gradle.properties            # JVM args, AndroidX on, R8 full mode, parallel/caching
├── gradle/wrapper/              # (wrapper jar/properties NOT yet committed — see below)
└── app/
    ├── build.gradle.kts         # namespace com.noop, applicationId com.noop.whoop, Compose + Room
    └── src/
        ├── main/
        │   ├── AndroidManifest.xml
        │   ├── java/com/noop/
        │   │   ├── protocol/    # Crc.kt  (+ Framing.kt, ParseFrame.kt, Schema.kt to come)
        │   │   ├── data/        # Entities.kt  (+ Daos.kt, NoopDatabase.kt to come)
        │   │   ├── analytics/   # Analytics.kt
        │   │   ├── ble/         # (BluetoothGatt manager to come)
        │   │   └── ui/          # (MainActivity + Compose screens to come)
        │   └── res/values/      # colors.xml, themes.xml, strings.xml
        └── test/java/com/noop/
            └── analytics/AnalyticsTest.kt
```

### Version contract

From `android/build.gradle.kts` and `android/app/build.gradle.kts` — keep these aligned; a Kotlin
bump forces matching KSP and Compose-compiler bumps:

| Component | Version | Notes |
| --- | --- | --- |
| Android Gradle Plugin | `8.5.2` | `com.android.application` |
| Kotlin | `1.9.24` | `org.jetbrains.kotlin.android` |
| KSP | `1.9.24-1.0.20` | `<kotlinVersion>-<kspVersion>`, must track Kotlin exactly |
| Compose BOM | `2024.06.00` | pins all Compose artifacts in lockstep |
| Compose compiler extension | `1.5.14` | matched to Kotlin 1.9.24 |
| Room | `2.6.1` | `room-runtime`, `room-ktx`, `room-compiler` (via KSP) |
| `compileSdk` / `targetSdk` | `34` | |
| `minSdk` | `26` | Android 8.0 — the floor for the current BLE permission split |
| `sourceCompatibility` / `jvmTarget` | `17` | JDK 17 |
| `applicationId` | `com.noop.whoop` | `.debug` suffix on debug builds |

The app declares **no `INTERNET` permission** by design (see
[Permissions](#permissions-and-the-no-internet-posture)) and sets `android:allowBackup="false"`.

---

## What exists vs. what is missing

Be honest about the state of the port before building on it.

**Present and ported** (under `android/app/src/main/java/com/noop/`):

- `protocol/Crc.kt` — `Crc.crc8`, `Crc.crc32`, `Crc.crc16Modbus`. **Ported verbatim** from
  `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` (same CRC8 table, same zlib CRC-32
  table generation, same CRC16-Modbus loop). Returns are widened (`Int`/`Long`) because Kotlin has
  no commonly-used unsigned return types, but carry only the low 8/16/32 bits.
- `data/Entities.kt` — Room `@Entity` classes mirroring the GRDB schema: `DeviceRow`, `HrSample`,
  `RrInterval`, `EventRow`, `BatterySample`, `Spo2Sample`, `SkinTempSample`, `RespSample`,
  `GravitySample`, `DailyMetric`, `SleepSession`, `MetricSeriesRow`. Natural/composite keys match
  the Swift `ON CONFLICT … DO NOTHING` upserts (use `OnConflictStrategy.IGNORE`).
- `analytics/Analytics.kt` — `Hrv.rmssd`, `Zones.zone` / `Zones.hrMaxTanaka`, `IllnessWatch.evaluate`.
  Ported from `Strand/App/AppModel.swift` (`rmssd`, `coachZone`, `evaluateIllness`).
- `test/java/com/noop/analytics/AnalyticsTest.kt` — JUnit unit tests for the analytics above
  (RMSSD known-vector, zone ladder/boundaries, Tanaka rounding, illness-watch flag logic). These
  are the **only** tests in the module today.
- Manifest, `res/values/{colors,themes,strings}.xml`, launcher mipmaps, and
  `res/xml/data_extraction_rules.xml`.

**Referenced but NOT yet present** (the build/manifest will not assemble until these land):

| Missing file | Referenced by | Needed for |
| --- | --- | --- |
| `com/noop/NoopApplication.kt` | `AndroidManifest.xml` (`android:name=".NoopApplication"`) | app `Application` subclass |
| `com/noop/ui/MainActivity.kt` | `AndroidManifest.xml` (launcher `<activity>`) | Compose entry point |
| `app/proguard-rules.pro` | `app/build.gradle.kts` (release `proguardFiles`) | R8 release build |
| `gradle/wrapper/gradle-wrapper.{jar,properties}`, `gradlew`, `gradlew.bat` | `./gradlew …` | reproducible Gradle version |
| `com/noop/protocol/Framing.kt` (`verifyFrame`, `Reassembler`) | BLE layer | frame validation + reassembly |
| `com/noop/protocol/ParseFrame.kt` (`parseFrame`) | decode/UI | field-level decode |
| `com/noop/protocol/Schema.kt` + bundled `whoop_protocol.json` asset | `parseFrame` | enum/packet specs |
| `com/noop/protocol/DeviceFamily.kt` (UUIDs, CLIENT_HELLO) | BLE layer | WHOOP 4.0 vs 5.0 |
| `com/noop/protocol/Commands.kt` (`WhoopCommand`) | BLE layer | build/send command frames |
| `com/noop/ble/*` (`BluetoothGatt` manager, frame router, collector, backfiller) | app | the BLE pipeline |
| `com/noop/data/*Dao.kt`, `NoopDatabase.kt` | app | Room DAOs + database |
| `com/noop/ui/*` Compose screens | app | the UI |

> The gradle wrapper is `.gitignore`d only at the artifact level (`android/.gradle/`,
> `android/build/`, `android/app/build/`, `android/local.properties`, `android/.idea/`,
> `android/*.iml`). The **wrapper script + properties are not ignored** and should be committed so
> the project builds on a clean checkout. If `gradle/wrapper/gradle-wrapper.properties` is absent,
> run `gradle wrapper --gradle-version 8.7` once (with a system Gradle that supports AGP 8.5) to
> generate it, then commit it.

---

## Build prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| JDK | **17** | AGP 8.5 / Kotlin 1.9 target JVM 17 |
| Android SDK | API **34** platform + build-tools; `minSdk` 26 | install via Android Studio SDK Manager or `sdkmanager` |
| Android Studio | current stable (Koala / Ladybug or newer) | optional but recommended; provides the SDK and emulator |
| Gradle | provided by the wrapper (target ~8.7) | do not rely on a global Gradle once the wrapper is committed |
| A physical WHOOP 4.0 or 5.0 strap | — | **required** for any real BLE validation; emulators have no BLE radio |
| A physical Android device with BLE | Android 8.0+ (API 26+) | the emulator **cannot** reach a real strap |

Point Gradle at the SDK with `android/local.properties` (untracked):

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

or export `ANDROID_HOME` / `ANDROID_SDK_ROOT`.

---

## Building

> These commands describe the intended flow. As noted above, `assembleDebug` will **fail** until
> the missing `NoopApplication`, `MainActivity`, and `proguard-rules.pro` exist and the wrapper is
> committed. The unit-test task runs today because the analytics + entities it exercises are present.

```bash
cd android

# Run the pure-Kotlin unit tests (analytics). No device needed.
./gradlew :app:testDebugUnitTest

# Assemble a debug APK (once the entry-point stubs exist).
./gradlew assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk  (applicationId com.noop.whoop.debug)

# Install onto a connected device and launch.
./gradlew installDebug
adb shell am start -n com.noop.whoop.debug/com.noop.ui.MainActivity

# Release build (needs proguard-rules.pro; R8 full mode + resource shrink are enabled).
./gradlew assembleRelease
```

Open `android/` directly in Android Studio (**File ▸ Open ▸ android/**) and let Gradle sync; run
the `app` configuration on a physical device.

---

## The protocol module (Kotlin port of `WhoopProtocol`)

The protocol module is the reverse-engineering core. It is **platform-pure**: it must not import
any Android Bluetooth types, so it can be unit-tested on the JVM exactly like `WhoopProtocol` runs
in Swift CLI tools and tests. The BLE layer is responsible for turning the UUID *strings* the
protocol exposes into `android.os.ParcelUuid` / `UUID` values.

### Framing and CRCs (`Crc.kt`, present)

Already ported verbatim from `Framing.swift`:

| Function | Algorithm | Guards |
| --- | --- | --- |
| `Crc.crc8(data)` | CRC-8, poly `0x07`, table-driven | WHOOP 4.0 frame length header |
| `Crc.crc32(data)` | zlib CRC-32, reflected, poly `0xEDB88320` | the frame payload (both families) |
| `Crc.crc16Modbus(data)` | CRC16-Modbus, poly `0xA001`, init `0xFFFF`, reflected | WHOOP 5.0 frame header |

### Frame envelopes (to port — `Framing.swift` → `Framing.kt`)

Two families, one payload CRC. Port `verifyFrame(_:)`, `verifyFrame(_:family:)`,
`frameFromPayload(...)`, and `Reassembler` from `Framing.swift`.

**WHOOP 4.0 envelope** (`DeviceFamily.whoop4`, CRC8 header):

```
[0]      SOF 0xAA
[1..2]   length  u16 LE
[3]      crc8(length bytes)
[4]      packet type
[5]      seq
[6]      cmd
[7..]    payload
[len..]  crc32 (zlib, LE) over inner bytes [4 .. len)
total = length + 4
```

**WHOOP 5.0 / MG envelope** (`DeviceFamily.whoop5`, CRC16-Modbus header — from the goose work):

```
[0]      SOF 0xAA
[1]      format byte (0x01)
[2..3]   declaredLength u16 LE   (= payload length + 4)
[4..5]   header bytes
[6..7]   CRC16-Modbus over frame[0..6], u16 LE
[8..]    inner record: [type][seq][cmd][data…]
tail     crc32 (zlib, LE) over the payload, 4 bytes
total = declaredLength + 8
```

`Reassembler.feed(fragment)` accumulates BLE notification fragments and emits complete frames; a
complete WHOOP 4.0 frame is `length + 4` bytes where `length = u16 LE at buf[1..3]`. Port the
`firstIndex(of: 0xAA)` resync logic exactly — partial fragments are the norm over GATT notifications.

### Decode (to port — `Interpreter.swift` → `ParseFrame.kt`)

`parseFrame(frame)` (WHOOP 4.0) and `parseFrame(frame, family)` (WHOOP 5.0) build a `ParsedFrame`
with `ok`, `typeName`, `seq`, `cmdName`, `crcOK`, `fields`, and a flat `parsed` map. The decoder is
**schema-driven** — it reads static field offsets/dtypes/enums from the bundled
`whoop_protocol.json`, then applies a per-type post-hook for irregular fields. The Kotlin port
should:

1. Bundle `whoop_protocol.json` as an `assets/` resource (or `res/raw/`) and parse it into a
   `Schema` data class mirroring `Schema.swift` (`enums`, `envelope`, `packets`, with a
   `byType` index built from each packet's `type` + `aliases`).
2. Implement the LE readers (`u8`/`u16`/`u32`/`i16`, nullable on out-of-range) and the
   `FieldBuilder`/post-hook pattern from `Interpreter.swift`.
3. Alias the WHOOP 5.0 "puffin" packet types onto their base names via `canonicalTypeName`:
   `38 (PUFFIN_COMMAND_RESPONSE) → COMMAND_RESPONSE`, `56 (PUFFIN_METADATA) → METADATA`
   (`DeviceFamily.swift`).

The enum groups in `whoop_protocol.json` are `PacketType` (16 entries), `MetadataType`,
`EventNumber`, and `CommandNumber` (77 entries). Decode the command name for COMMAND (35) /
COMMAND_RESPONSE (36) frames via the `CommandNumber` enum.

### Device family + GATT identity (to port — `DeviceFamily.swift` → `DeviceFamily.kt`)

`DeviceFamily` exposes everything the BLE layer needs as plain strings. Port these constants exactly:

| | WHOOP 4.0 (`whoop4`) | WHOOP 5.0 (`whoop5`) |
| --- | --- | --- |
| Header CRC | CRC8 (poly 0x07) | CRC16-Modbus |
| Service UUID | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Command/write char | `61080002-…` | `fd4b0002-…` |
| Other chars | `…0003, …0004, …0005` | `…0003, …0004, …0005, …0007` |
| CLIENT_HELLO | none | `AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D` |

The WHOOP 5.0 CLIENT_HELLO is a fully-formed type-35 (COMMAND) frame written immediately after GATT
discovery; transcribe it verbatim (`DeviceFamily.whoop5ClientHello`).

### Commands (to port — `Commands.swift` → `Commands.kt`)

Port the **curated, safe** `WhoopCommand` enum from `Strand/BLE/Commands.swift`. It intentionally
**excludes** destructive commands (reboot, firmware load, force-trim, ship-mode, power-cycle,
fuel-gauge reset, BLE DFU) so the command sender can never brick or wipe the strap — preserve that
exclusion. Raw values are the on-wire command codes; the ones the connect/offload lifecycle relies on:

| Command | Code | Role |
| --- | --- | --- |
| `toggleRealtimeHR` | 3 | start/stop realtime HR stream |
| `setClock` | 10 | set strap RTC (8-byte payload: `[seconds u32 LE][subseconds u32 LE]`) |
| `getClock` | 11 | request device↔wall clock correlation (**empty** payload) |
| `sendHistoricalData` | 22 | trigger the type-47 historical offload (payload `[0x00]`) |
| `historicalDataResult` | 23 | ack a HISTORY_END chunk (`[0x01] + endData`, confirmed write) |
| `getBatteryLevel` | 26 | also used as the **bond** write |
| `getDataRange` | 34 | refresh the strap's stored range for the liveness watchdog |
| `getHelloHarvard` | 35 | session hello |
| `sendR10R11Realtime` | 63 | the real on/off for the type-43 raw flood (`[0x00]` to stop) |
| `setAlarmTime` / `getAlarmTime` / `runAlarm` / `disableAlarm` | 66/67/68/69 | firmware alarm |
| `runHapticsPattern` | 79 | buzz the motor (`[patternId, numLoops, 0,0,0]`) |

`WhoopCommand.frame(seq, payload)` builds the framed COMMAND packet for WHOOP 4.0:
`[0xAA][len u16 LE][crc8(len)][type=35][seq][cmd][payload…][crc32 LE]`, where `len = (3 + payload) + 4`,
crc8 is over the two length bytes, and crc32 (zlib) is over `[type][seq][cmd][payload]`. Port this
builder exactly — it is the most-exercised write path.

---

## Android BLE layer

This is the **highest-risk** part of the port and the least validated. The macOS reference is
`Strand/BLE/BLEManager.swift` (CoreBluetooth). The Android equivalent uses `BluetoothGatt`. The
**sequence is identical**; only the API differs.

### CoreBluetooth → Android mapping

| CoreBluetooth (macOS, verified) | Android `BluetoothGatt` (to build) |
| --- | --- |
| `CBCentralManager.scanForPeripherals(withServices: [service])` | `BluetoothLeScanner.startScan(filters, settings, callback)` with a `ScanFilter` on the service UUID |
| `central.connect(peripheral)` | `device.connectGatt(context, autoConnect=false, gattCallback, TRANSPORT_LE)` |
| `peripheral.discoverServices(...)` | `gatt.discoverServices()` → `onServicesDiscovered` |
| `peripheral.writeValue(_, for:, type: .withResponse)` | `gatt.writeCharacteristic(...)` with `WRITE_TYPE_DEFAULT` (API 33+: `writeCharacteristic(char, value, writeType)`) |
| `.withoutResponse` | `WRITE_TYPE_NO_RESPONSE` |
| `peripheral.setNotifyValue(true, for:)` | `gatt.setCharacteristicNotification(char, true)` **plus** write `ENABLE_NOTIFICATION_VALUE` to the `0x2902` CCCD descriptor |
| `didUpdateValueFor` delegate | `onCharacteristicChanged` callback |
| `didWriteValueFor` (confirmed-write = bond) | `onCharacteristicWrite` with `GATT_SUCCESS` |

### The connect → bond → stream sequence (must match `BLEManager`)

1. **Scan** filtered by the family service UUID (`61080001-…` for 4.0, `fd4b0001-…` for 5.0).
2. **Connect** and **discover services**, then discover the family characteristics.
3. **BOND via one confirmed write.** This is the load-bearing trick: writing
   `GET_BATTERY_LEVEL` (cmd 26) to the command/write characteristic (`…0002`) with
   `WRITE_TYPE_DEFAULT` triggers just-works bonding. On Android, prefer letting the GATT write drive
   pairing; you may also need to handle `BluetoothDevice.createBond()` / the
   `ACTION_BOND_STATE_CHANGED` broadcast depending on the OEM stack. Bond confirmation =
   `onCharacteristicWrite(GATT_SUCCESS)`.
4. **Subscribe** (notify) to the command-notify, event-notify, and data-notify characteristics
   (`…0003/0004/0005`), plus the standard Heart Rate (`0x2A37`, service `0x180D`) and Battery
   (`0x2A19`, service `0x180F`) characteristics. The standard HR profile is the **reliable** R-R
   and HR source and works **unbonded**.
5. **Run the connect handshake EXACTLY ONCE per connection.** On macOS this is guarded by
   `connectHandshakeDone` because `didWriteValueFor` re-fires on every confirmed write; the same
   guard is mandatory on Android (`onCharacteristicWrite` likewise fires per write). Re-blasting
   `hello`/`SET_CLOCK` mid-offload was the documented root cause of the strap refusing to serve
   type-47. The handshake: `getHelloHarvard` → `getAdvertisingNameHarvard` → `setClock` →
   `getClock` (empty payload) → `sendR10R11Realtime [0x00]` (stop the raw flood) → `getDataRange`,
   then after ~1.5 s start the historical offload.
6. **Reassemble** notification fragments on the three custom characteristics through `Reassembler`,
   route each complete frame, run clock correlation, and during a backfill route only genuine
   offload frames (types `47/48/49/50` — HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS), dropping
   the live `40/43` flood so the idle watchdog tracks real progress.

### Android-specific BLE gotchas

- **Serialize GATT operations.** Unlike CoreBluetooth, Android's GATT stack allows **one
  outstanding operation at a time**. Queue writes / reads / descriptor writes and only issue the
  next on the matching callback, or operations will silently drop. The Swift `send(...)` path is
  fire-and-forget because CoreBluetooth queues internally; the Kotlin port must add its own queue.
- **CCCD descriptor.** `setCharacteristicNotification(true)` alone is not enough on Android — you
  must also write `BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE` to the Client Characteristic
  Configuration descriptor (`00002902-0000-1000-8000-00805f9b34fb`).
- **MTU.** Consider `requestMtu(...)` after connect; the reassembler tolerates any fragment size, so
  this is an optimization, not a correctness requirement.
- **Foreground service.** To keep collecting/offloading while backgrounded, run the GATT work inside
  a foreground service of type `connectedDevice` (the manifest already declares
  `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE`). Android has no direct analogue to
  CoreBluetooth state restoration — a foreground service is the equivalent mechanism.
- **Strap must be out of range of the official app** during initial bonding, worn, and charged
  enough to report a non-zero heart rate.

### Debugging the strap connection

The BLE client keeps a running **strap log** of the connection's control flow — scan results,
the bond/handshake state machine, every command sent (name + payload hex), and offload progress
(trim cursors, chunk acks). It is the primary tool for **debugging and protocol development** on
Android, and the same log is what users attach to bug reports.

By default the log is kept **only** in an in-memory ring buffer (so a normal user never writes the
connection log to the device-wide system log). To watch a session live while developing, turn the
log on:

1. In the app: **Settings → Strap → "Debug logging"** (off by default).
2. Then tail it over adb, filtered to the BLE client tag:

   ```bash
   adb logcat -s WhoopBleClient
   # e.g.
   #   D WhoopBleClient: Discovered WHOOP 5AG… (rssi -52) — connecting
   #   D WhoopBleClient: → TOGGLE_REALTIME_HR payload=01 (puffin)
   #   D WhoopBleClient: Backfill: acked chunk trim=113681
   #   D WhoopBleClient: Backfill: session ended — reason=HISTORY_COMPLETE
   ```

The toggle drives `WhoopBleClient.debugLogcat` (persisted as `NoopPrefs.KEY_DEBUG_LOGGING`); it
gates only the `Log.d` call. Whether or not it is on, **Settings → Strap → "Share strap log"**
exports the same in-app buffer to a file (the path for users with no adb). What the log does and
does not contain — and why logcat is opt-in — is covered in `PRIVACY_SECURITY.md` §2.4.

---

## Storage with Room

`com.noop.data.Entities.kt` mirrors the GRDB schema from
`Packages/WhoopStore/Sources/WhoopStore/Database.swift`. To finish the storage layer, add DAOs and a
`@Database` and keep these invariants:

- **Composite natural keys preserved exactly** so `OnConflictStrategy.IGNORE` reproduces the Swift
  `ON CONFLICT(...) DO NOTHING` dedupe:

  | Entity | Table | Primary key |
  | --- | --- | --- |
  | `HrSample` | `hrSample` | `(deviceId, ts)` |
  | `RrInterval` | `rrInterval` | `(deviceId, ts, rrMs)` |
  | `EventRow` | `event` | `(deviceId, ts, kind)` |
  | `BatterySample` | `battery` | `(deviceId, ts)` |
  | `Spo2Sample` | `spo2Sample` | `(deviceId, ts)` |
  | `SkinTempSample` | `skinTempSample` | `(deviceId, ts)` |
  | `RespSample` | `respSample` | `(deviceId, ts)` |
  | `GravitySample` | `gravitySample` | `(deviceId, ts)` |
  | `DailyMetric` | `dailyMetric` | `(deviceId, day)` |
  | `SleepSession` | `sleepSession` | `(deviceId, startTs)` |
  | `MetricSeriesRow` | `metricSeries` | `(deviceId, day, key)` + index `idx_metricSeries_device_key_day (deviceId, key, day)` |
  | `DeviceRow` | `device` | `id` |

- **Timestamps are wall-clock unix seconds.** Swift stores them as `Int`; the entities widen to
  `Long` for safety. `day` columns are `"YYYY-MM-DD"` strings.
- **`payloadJSON` is deterministic sorted-keys JSON** (the parsed event fields minus
  `event`/`event_timestamp`). Match `StreamStore.encodePayload` so event rows are byte-identical
  across platforms.
- **Schema version parity.** The GRDB migrations run `v1`…`v9`. The entities already carry forward
  later additions (e.g. `synced` flags, `battery.charging` from v6, the v7 in-sleep aggregates
  `spo2Pct`/`skinTempDevC`/`respRateBpm`, and the v9 `metricSeries`). When you add the Room
  `@Database`, set its `version` and migrations to reach the same logical schema; Room generates the
  SQL, so verify the emitted `CREATE TABLE`/index against `Database.swift` rather than assuming.

Some Swift tables are not yet represented as Room entities (`rawBatch`, `cursors`, `journal`,
`workout`, `appleDaily`) — add them when the collector / importer / journal features are ported.

The database is created **without** an `INTERNET` permission and lives entirely in the app's private
storage; nothing is uploaded.

---

## Analytics

`com.noop.analytics.Analytics.kt` ports the pure math from `Strand/App/AppModel.swift`:

- **`Hrv.rmssd(rr)`** — root-mean-square of successive R-R differences (ms); returns `0.0` for
  fewer than two intervals (matches the Swift `rr.count >= 2` guard).
- **`Zones.zone(hr, hrMax)`** — the `pct = hr/hrMax` ladder (`≥0.9→5, ≥0.8→4, ≥0.7→3, ≥0.6→2,
  else 1`), with a fallback to zone 1 when `hrMax ≤ 0`. `Zones.hrMaxTanaka(age)` = `round(208 − 0.7·age)`.
- **`IllnessWatch.evaluate(days)`** — compares the last ~2 days against a ~28-day baseline ending 3
  days ago across resting HR, HRV, skin-temp deviation, and respiration; surfaces a banner when 2+
  anomalies fire. Requires ≥14 days of history. The Swift `behavior.illnessWatch` UI toggle is
  intentionally omitted from this pure function — the caller decides whether to run it.

`AnalyticsTest.kt` locks these against known vectors. The heavier `StrandAnalytics` package
(`RecoveryScorer`, `StrainScorer`, `SleepStager`, `CorrelationEngine`, `Baselines`, …) is **not yet
ported**; port it module-by-module against the Swift sources and add matching JVM unit tests.

---

## Compose UI

The UI is Jetpack Compose (Material 3). Today only the theme resources
(`res/values/colors.xml`, `themes.xml` with `Theme.NOOP`, `strings.xml` with `app_name = "NOOP"`)
exist; `MainActivity` and the screens are not yet written. The dependency set in
`app/build.gradle.kts` is already wired for Compose (BOM `2024.06.00`, Material 3, Material icons
extended, `activity-compose`, `navigation-compose`, `lifecycle-viewmodel-compose`) and Coroutines.

When building screens, follow the reference app's information architecture
(`Strand/Screens/`): Today, Live, Sleep, Trends, Stress, Workouts, Compare, Insights, Metric
Explorer, Data Sources, Settings, Support. Treat `StrandDesign` (palette / components / charts) as
the spec for tokens and chart styles, re-expressed as a Compose theme — do not hardcode colors.

---

## Permissions and the no-internet posture

The manifest is deliberately minimal and **declares no `INTERNET` permission** — nothing leaves the
device. Permissions, straight from `android/app/src/main/AndroidManifest.xml`:

| Permission | API range | Why |
| --- | --- | --- |
| `BLUETOOTH_SCAN` (`neverForLocation`) | 31+ | scan for the strap; opt out of location coupling |
| `BLUETOOTH_CONNECT` | 31+ | connect / bond / GATT I/O |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` | ≤30 | legacy install-time BLE perms |
| `ACCESS_FINE_LOCATION` | ≤30 | required for BLE scans on API 26–30 only |
| `FOREGROUND_SERVICE` | all | keep the link alive while backgrounded |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | 34+ | typed foreground service for the GATT connection |
| `<uses-feature bluetooth_le required="true">` | — | BLE is mandatory hardware |

On API 31+ you must **request `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` at runtime** before scanning
or connecting. `android:allowBackup="false"` and the `data_extraction_rules.xml` keep the local DB
out of cloud/device-transfer backups — consistent with "your data stays on your device."

---

## Donations

NOOP is free and works fully without paying anything; donations are optional support, never a
paywall. The Android Support screen should reuse the same addresses as the macOS app
(`Strand/System/ProjectInfo.swift`, kept in sync with `docs/DONATIONS.md`):

| Symbol | Name | Address |
| --- | --- | --- |
| BTC | Bitcoin | `bc1qn2gkl7wslwpws06mvazjn2uu689zlkv7kg3kf5` |
| ADA | Cardano | `addr1qxsju3y0mlke2h6h2g6qgnq4r3jstngtyjxs0nnp5zrv28zv8p5rgzruxyjz33j9k23pffta8z639e2snjdd4vcetfqsn4vwr3` |
| ETH | Ethereum | `0xd64D508b531c4b1297Ca4023C774e0E97aA67B7F` |
| XRP | XRP | `rpvijHi2nVY9WWAJhojsAX5tJmHdmLtFhq` |

Present them as copyable rows with a copy-to-clipboard action and accessible labels, mirroring
`Strand/Screens/SupportView.swift`. Keep the screen attribution-first (credit the upstream
reverse-engineering) with donations clearly marked optional.

---

## Verification checklist

Nothing here has been validated on Android yet. Treat each item as **unverified** until checked off
against a real build, a real device, and a real strap.

**Build & static**

- [ ] Commit the gradle wrapper (`gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.{jar,properties}`).
- [ ] Add the missing entry points: `com/noop/NoopApplication.kt`, `com/noop/ui/MainActivity.kt`,
      `app/proguard-rules.pro`.
- [ ] `./gradlew :app:testDebugUnitTest` is green (analytics vectors).
- [ ] `./gradlew assembleDebug` produces `app-debug.apk`.
- [ ] `./gradlew assembleRelease` succeeds with R8 full mode + resource shrinking.
- [ ] APK declares **no `INTERNET` permission** (`aapt dump permissions app-debug.apk`).

**Protocol parity (JVM, no device)**

- [ ] `Crc.crc8/crc32/crc16Modbus` match the Swift `FramingTests` vectors bit-for-bit.
- [ ] Port `verifyFrame` + `Reassembler` and reproduce `FramingTests` / `ReassemblerTests`.
- [ ] Port `parseFrame` (4.0) + `parseFrame(family: whoop5)` and reproduce `ParityTests` /
      `StreamsParityTests` / `HistoricalStreamsParityTests` against the same fixtures.
- [ ] `WhoopCommand.frame(seq, payload)` reproduces the macOS command bytes (e.g. CLIENT_HELLO and a
      known `GET_BATTERY_LEVEL` frame).
- [ ] The bundled `whoop_protocol.json` asset is the same file as the Swift resource (same
      `version`, enum counts: PacketType 16, CommandNumber 77).

**Storage parity (JVM/instrumented)**

- [ ] Room-generated `CREATE TABLE`/index SQL matches `Database.swift` for every ported table
      (column names, types, composite PKs, the `metricSeries` index).
- [ ] `OnConflictStrategy.IGNORE` dedupes on the natural keys exactly like the GRDB upserts.
- [ ] `payloadJSON` for a decoded event equals the Swift `StreamStore.encodePayload` output
      (sorted keys, `event`/`event_timestamp` removed).

**BLE on a real device with a real strap (the unproven layer)**

- [ ] Runtime permission flow: `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT` granted on API 31+.
- [ ] Scan finds the strap by the family service UUID (4.0 `61080001-…`, 5.0 `fd4b0001-…`).
- [ ] Connect → discover services → discover the family characteristics.
- [ ] **Bond via the single confirmed write** of `GET_BATTERY_LEVEL` to `…0002`
      (`onCharacteristicWrite(GATT_SUCCESS)`).
- [ ] CCCD `0x2902` descriptor write enables notifications on `…0003/0004/0005`, `0x2A37`, `0x2A19`.
- [ ] GATT operation queue prevents dropped writes (one in flight at a time).
- [ ] Connect handshake runs **exactly once** per connection (the `connectHandshakeDone` guard) —
      no `hello`/`SET_CLOCK` re-blast mid-offload.
- [ ] Standard HR (`0x2A37`) yields plausible HR (30–220 bpm) and R-R intervals.
- [ ] `SET_CLOCK` (8-byte payload) latches; `GET_CLOCK` (empty payload) returns a clock correlation.
- [ ] `sendR10R11Realtime [0x00]` stops the ~2/s type-43 raw flood.
- [ ] Historical offload (`sendHistoricalData [0x00]`) streams HISTORY_START → type-47 →
      HISTORY_END (acked via `historicalDataResult [0x01]+endData`) → HISTORY_COMPLETE.
- [ ] WHOOP 5.0 path: CLIENT_HELLO write + CRC16-Modbus header validation on a real 5.0 strap.
- [ ] Foreground service keeps the link alive while backgrounded.
- [ ] Decoded rows land in Room and survive an app restart.

---

## Credits

The Android client re-implements protocol and behavior built on prior community
reverse-engineering and interoperability work:

- **`johnmiddleton12/my-whoop`** — WHOOP 4.0 BLE protocol; the `WhoopProtocol` / `WhoopStore`
  packages the Kotlin protocol and storage ports follow.
- **`b-nnett/goose`** — WHOOP 5.0 / MG BLE protocol (service family `fd4b0001-…`, CRC16-Modbus
  header, CLIENT_HELLO, "puffin" packet types) that the WHOOP-5 path is ported from.

See [`../ATTRIBUTION.md`](../ATTRIBUTION.md) for full detail. NOOP contains no WHOOP proprietary
code, firmware, logos, or assets, operates only with the user's own device and data, and is **not a
medical device**.
