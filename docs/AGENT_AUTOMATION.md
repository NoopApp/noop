# Agent Automation

NOOP has repo-local helpers for agent-driven app exploration.

## Android with agent-device

Use the demo debug flavor on emulators. It installs as `com.noop.whoop.demo.debug`,
starts with synthetic data, and can skip onboarding through debug-only deep links.

```sh
Tools/agent-device-android.sh doctor
Tools/agent-device-android.sh install
Tools/agent-device-android.sh open live
Tools/agent-device-android.sh snapshot
```

Route deep links:

```text
noop://agent/<route>?onboarded=1
noop://agent/screen/<route>?onboarded=1
noop://agent?route=<route>&onboarded=1
```

Supported routes:

```text
today intelligence live intervals sleep breathe stress workouts trends coach
insights explore compare health apple_health automations data_sources
notifications support settings
```

Stable selectors exposed through Compose test tags:

```text
id="nav-open"
id="nav-<route>"
id="screen-<route>"
id="noop-root"
```

The wrapper defaults can be changed with environment variables:

```sh
ANDROID_SERIAL=emulator-5554 Tools/agent-device-android.sh open settings
NOOP_ANDROID_APP_ID=com.noop.whoop.debug \
NOOP_ANDROID_GRADLE_TASK=:app:assembleFullDebug \
NOOP_ANDROID_APK="$PWD/android/app/build/outputs/apk/full/debug/app-full-debug.apk" \
  Tools/agent-device-android.sh install
```

Emulators are good for UI navigation, seeded demo data, screenshots, and accessibility
snapshots. A real Android phone and WHOOP strap are still required for BLE validation.

## iOS with serve-sim

`serve-sim` streams a booted Apple simulator and provides normalized-coordinate input.
Use the wrapper to avoid memorizing the CLI flags:

```sh
Tools/serve-sim-ios.sh doctor
Tools/serve-sim-ios.sh start
Tools/serve-sim-ios.sh list
Tools/serve-sim-ios.sh kill
```

The JSON from `start` includes `url` and `streamUrl`. Stop helpers with `kill` when
finished so the default ports are released.
