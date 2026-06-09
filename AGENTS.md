# NOOP Agent Notes

## Android UI Automation

Use the demo debug Android app for emulator exploration. It has seeded data and does
not require a WHOOP strap.

```sh
Tools/agent-device-android.sh install
Tools/agent-device-android.sh open today
Tools/agent-device-android.sh snapshot
```

Supported route names:

```text
today intelligence live intervals sleep breathe stress workouts trends coach
insights explore compare health apple_health automations data_sources
notifications support settings
```

The Android app exposes debug deep links for direct navigation:

```text
noop://agent/<route>?onboarded=1
noop://agent/screen/<route>?onboarded=1
noop://agent?route=<route>&onboarded=1
```

`onboarded=1` is honored only in debug builds. It marks onboarding and the changelog
as complete so an agent can land directly in the app shell.

Stable Compose test tags are exported as Android resource ids:

- `nav-open`
- `nav-<route>`
- `screen-<route>`
- `noop-root`

Prefer `agent-device` selectors such as `id="nav-open"` or `id="screen-live"`
over raw coordinates.

## iOS Simulator Preview

For iOS simulator streaming, use the serve-sim wrapper:

```sh
Tools/serve-sim-ios.sh doctor
Tools/serve-sim-ios.sh start
Tools/serve-sim-ios.sh list
Tools/serve-sim-ios.sh kill
```

The simulator cannot exercise BLE. Use it only for UI preview and navigation; use a
real device for strap pairing and protocol validation.
