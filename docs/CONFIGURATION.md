<!-- generated-by: gsd-doc-writer -->
# Configuration

NOOP is a fully offline app — there is no server, no cloud account, and no environment to
configure before running. All data lives in a local SQLite database on your device. This
document covers every knob that exists: build-time settings for macOS and Android, app
entitlements, and the one opt-in networked feature (AI Coach).

---

## macOS build configuration

Source of truth: `project.yml` (XcodeGen input — never hand-edit `Strand.xcodeproj`).

### Key build settings

| Setting | Value | Where |
|---|---|---|
| `MARKETING_VERSION` | `1.72` | `project.yml` → `settings.base` |
| `CURRENT_PROJECT_VERSION` | `1` | `project.yml` → `settings.base` |
| `SWIFT_VERSION` | `5.0` | `project.yml` → `settings.base` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.noopapp.noop` | `project.yml` → target `Strand` |
| `PRODUCT_NAME` | `NOOP` | `project.yml` → target `Strand` |
| `PRODUCT_MODULE_NAME` | `Strand` | `project.yml` → target `Strand` |
| Deployment target | macOS 13.0 | `project.yml` → `options.deploymentTarget.macOS` |
| Bundle ID prefix | `com.noopapp` | `project.yml` → `options.bundleIdPrefix` |
| Architectures | `$(ARCHS_STANDARD)` — universal | `project.yml` → `settings.base` |
| Release: only active arch | `NO` (builds universal binary) | `project.yml` → `settings.configs.Release` |

### Code signing

`DEVELOPMENT_TEAM` is intentionally left empty in the repository so any contributor can build
without an Apple Developer account. Three signing paths are supported:

| Path | Requirement | Notes |
|---|---|---|
| Ad-hoc (`CODE_SIGN_IDENTITY="-"`) | None | Runs only on the build Mac; no Gatekeeper warning |
| Personal Team (free Apple ID) | Apple ID | Runs on other Macs; Gatekeeper warns "unidentified developer" |
| Developer ID (paid) | $99/year Apple Developer Program | Runs anywhere after notarisation; no Gatekeeper warning |

To use Personal Team or Developer ID signing, set `DEVELOPMENT_TEAM` in `project.yml` and
re-run `xcodegen generate`. Do not commit your team ID to the public repository.

For CI, pass `CODE_SIGNING_ALLOWED=NO` to skip signing entirely (compile-and-verify only, no
runnable `.app`). See [BUILD.md](BUILD.md) sections 3b and 3c for the full signing workflows.

`ENABLE_HARDENED_RUNTIME: YES` is set in the target settings. This closes the
`DYLD_INSERT_LIBRARIES` injection vector on distributed builds; the app uses no JIT or
unsigned-exec memory.

---

## Android build configuration

Source of truth: `android/app/build.gradle.kts`.

### SDK and version settings

| Setting | Value |
|---|---|
| `applicationId` | `com.noop.whoop` |
| `namespace` | `com.noop` |
| `compileSdk` | 34 |
| `minSdk` | 26 (Android 8.0) |
| `targetSdk` | 34 |
| `versionCode` | 81 |
| `versionName` | `1.72` |
| JVM target | 17 |
| Kotlin compiler extension | `1.5.14` (matched to Kotlin 1.9.24) |

### Build types

| Type | `applicationIdSuffix` | Minify | Notes |
|---|---|---|---|
| `debug` | `.debug` | off | `versionName` gets `-debug` suffix; uses debug keystore |
| `release` | — | off | R8 full-mode is disabled to avoid runtime crashes on reflective paths (Compose/Room/Tink); APK is ~20 MB but reliable |

### Product flavors (`tier` dimension)

Two flavors install side-by-side so anyone can explore the app without a strap:

| Flavor | Application ID | `ENABLE_DEMO` | Description |
|---|---|---|---|
| `full` | `com.noop.whoop` | `false` | The real app. Starts empty; pair a strap or import data. |
| `demo` | `com.noop.whoop.demo` | `true` | Preloaded with 120 days of synthetic data and a visible DEMO badge; no strap required. |

Build commands:

```bash
./gradlew assembleFullRelease   # full-tier release APK
./gradlew assembleDemoRelease   # demo-tier release APK
./gradlew assembleFullDebug     # full-tier debug APK (default for development)
```

### Gradle properties (`android/gradle.properties`)

| Property | Value | Effect |
|---|---|---|
| `org.gradle.jvmargs` | `-Xmx2048m -Dfile.encoding=UTF-8` | Daemon heap |
| `org.gradle.parallel` | `true` | Parallel task execution |
| `org.gradle.caching` | `true` | Build cache |
| `org.gradle.configureondemand` | `true` | Configure only needed projects |
| `android.useAndroidX` | `true` | Required (Compose, Room, lifecycle) |
| `kotlin.code.style` | `official` | IDE style |
| `android.enableR8.fullMode` | `true` | R8 full-mode (release proguard step, minify currently off) |
| `android.nonTransitiveRClass` | `true` | Smaller R class (faster builds) |

---

## Android release signing (`keystore.properties`)

Debug builds use the Android SDK debug keystore automatically — no configuration needed.

For a signed release APK, create `android/keystore.properties` (this file is git-ignored and
must never be committed):

```properties
storeFile=../noop-release.jks
storePassword=your-store-password
keyAlias=noop-release
keyPassword=your-key-password
```

Generate the keystore once:

```bash
keytool -genkey -v \
  -keystore noop-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias noop-release
```

Place `noop-release.jks` at the path referenced by `storeFile` (relative to `android/`). When
`keystore.properties` is present, `build.gradle.kts` picks it up automatically and uses the
release signing config. When it is absent (fresh clone, CI without secrets), the release build
falls back to the debug key so `assembleRelease` always succeeds.

---

## macOS app entitlements

`Strand/Resources/Strand.entitlements` — applied at build time by XcodeGen.

| Entitlement | Value | Reason |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | macOS sandboxing — required for distribution |
| `com.apple.security.device.bluetooth` | `true` | CoreBluetooth access to scan and connect to the WHOOP strap |
| `com.apple.security.files.user-selected.read-write` | `true` | Read WHOOP CSV exports and Apple Health ZIP files that the user opens via a file picker |

The Bluetooth usage description shown to the user on first launch comes from `Info.plist`:

> "NOOP connects directly to your WHOOP strap over Bluetooth to read heart rate, R-R intervals,
> battery, and sensor data locally on your Mac. Nothing leaves your device."

---

## Optional feature: AI Coach

The AI Coach is the single opt-in networked feature. Everything else in NOOP is strictly
offline. Nothing is sent to any external service until the user explicitly enables the coach
by entering their own API key.

### How it works

- The user pastes their own API key from OpenAI or Anthropic into the Coach settings screen.
- NOOP sends only a compact plain-text summary of the user's metrics plus their question — no
  raw sensor samples, no identifiers.
- The key is never embedded in the app; NOOP has no built-in key.

### Where the key is stored

| Platform | Storage mechanism |
|---|---|
| macOS | macOS Keychain (`kSecClassGenericPassword`, service `com.noop.aicoach`, accessible after first unlock) |
| Android | Jetpack `EncryptedSharedPreferences` backed by Android Keystore (AES256-GCM, hardware-backed where available) |

The key is never written to disk in the clear, never logged, and never included in backups by
default.

### Supported providers and default models

| Provider | Default model | Endpoint |
|---|---|---|
| OpenAI | `gpt-4o-mini` | `https://api.openai.com/v1/chat/completions` |
| Anthropic | `claude-sonnet-4-6` | `https://api.anthropic.com/v1/messages` |

Additional models offered in the picker: `gpt-4o`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`
(OpenAI); `claude-opus-4-8`, `claude-haiku-4-5-20251001`, `claude-3-7-sonnet-latest`, and
others (Anthropic). A free-text "Custom…" entry accepts any model ID the provider supports. The
model list can also be refreshed live from the provider's models endpoint using the saved key.

### Data consent

A separate data-consent toggle controls whether the user's metrics are included in the context
sent to the provider. The default is off — no numbers are transmitted until the user explicitly
enables it. When consent is off, the coach receives a note explaining that data was not shared,
not the actual metrics.

### How to enter the key (macOS)

1. Open NOOP → navigate to the Coach screen.
2. In Coach settings, select your provider (OpenAI or Anthropic).
3. Paste your API key and press Save. The key is stored in the macOS Keychain immediately.
4. Optionally enable the data-consent toggle to allow the coach to reference your metrics.

### How to enter the key (Android)

1. Open NOOP → navigate to the Coach screen.
2. Tap the settings icon → select your provider.
3. Paste your API key and confirm. The key is stored in EncryptedSharedPreferences.

---

## No server-side configuration

NOOP has no server, no cloud backend, no account, and no environment variables to set before
running. There is no `.env` file, no secrets manager, and no deployment-time configuration.
All data is local; the only outbound network traffic is the optional AI Coach request described
above, and that traffic originates from the user's device using the user's own API key.
