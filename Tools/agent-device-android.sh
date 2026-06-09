#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"

AGENT_DEVICE_PACKAGE="${AGENT_DEVICE_PACKAGE:-agent-device@latest}"
AGENT_DEVICE_SESSION="${AGENT_DEVICE_SESSION:-noop-android}"
NOOP_ANDROID_APP_ID="${NOOP_ANDROID_APP_ID:-com.noop.whoop.demo.debug}"
NOOP_ANDROID_GRADLE_TASK="${NOOP_ANDROID_GRADLE_TASK:-:app:assembleDemoDebug}"
NOOP_ANDROID_APK="${NOOP_ANDROID_APK:-$ANDROID_DIR/app/build/outputs/apk/demo/debug/app-demo-debug.apk}"

ROUTES=(
  today intelligence
  live intervals
  sleep breathe stress
  workouts trends
  coach insights explore compare
  health apple_health
  automations data_sources notifications support settings
)

usage() {
  cat <<'USAGE'
Usage: Tools/agent-device-android.sh <command> [args]

Commands:
  doctor              Show adb + agent-device Android device discovery.
  build               Build the demo debug APK.
  install             Build and install the APK with agent-device.
  open [route]        Open a top-level route with noop://agent/<route>?onboarded=1.
  snapshot            Capture interactive refs for the current screen.
  screenshot [path]   Capture a screenshot.
  routes              Print supported route names.

Environment:
  ANDROID_SERIAL              Target a specific emulator/device serial.
  AGENT_DEVICE_PACKAGE        agent-device npm package, default agent-device@latest.
  AGENT_DEVICE_SESSION        agent-device session name, default noop-android.
  NOOP_ANDROID_APP_ID         Package id, default com.noop.whoop.demo.debug.
  NOOP_ANDROID_GRADLE_TASK    Build task, default :app:assembleDemoDebug.
  NOOP_ANDROID_APK            APK path, default app-demo-debug.apk.

Examples:
  Tools/agent-device-android.sh install
  Tools/agent-device-android.sh open live
  Tools/agent-device-android.sh snapshot
USAGE
}

agent_device() {
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    npx --yes "$AGENT_DEVICE_PACKAGE" "$@" \
      --platform android \
      --session "$AGENT_DEVICE_SESSION" \
      --session-lock strip \
      --serial "$ANDROID_SERIAL"
  else
    npx --yes "$AGENT_DEVICE_PACKAGE" "$@" \
      --platform android \
      --session "$AGENT_DEVICE_SESSION"
  fi
}

is_route() {
  local route="$1"
  local known
  for known in "${ROUTES[@]}"; do
    [[ "$known" == "$route" ]] && return 0
  done
  return 1
}

deep_link_for() {
  local route="$1"
  if [[ "$route" == noop://* ]]; then
    printf '%s\n' "$route"
    return 0
  fi

  if ! is_route "$route"; then
    printf 'Unknown route: %s\n\nSupported routes:\n' "$route" >&2
    printf '  %s\n' "${ROUTES[@]}" >&2
    return 2
  fi

  printf 'noop://agent/%s?onboarded=1\n' "$route"
}

build_apk() {
  (cd "$ANDROID_DIR" && ./gradlew "$NOOP_ANDROID_GRADLE_TASK" --console=plain)
}

command="${1:-help}"
shift || true

case "$command" in
  doctor)
    adb devices
    agent_device devices
    ;;
  build)
    build_apk
    ;;
  install)
    build_apk
    agent_device install "$NOOP_ANDROID_APP_ID" "$NOOP_ANDROID_APK"
    ;;
  open|screen)
    route="${1:-today}"
    agent_device open "$(deep_link_for "$route")"
    ;;
  snapshot)
    agent_device snapshot -i
    ;;
  screenshot)
    path="${1:-$ROOT_DIR/tmp/noop-android.png}"
    mkdir -p "$(dirname "$path")"
    agent_device screenshot "$path"
    printf '%s\n' "$path"
    ;;
  routes)
    printf '%s\n' "${ROUTES[@]}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 2
    ;;
esac
