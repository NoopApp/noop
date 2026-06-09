#!/usr/bin/env bash
set -euo pipefail

SERVE_SIM_PACKAGE="${SERVE_SIM_PACKAGE:-serve-sim@latest}"

usage() {
  cat <<'USAGE'
Usage: Tools/serve-sim-ios.sh <command> [device]

Commands:
  doctor          Check serve-sim prerequisites and list booted Apple simulators.
  start [device]  Start serve-sim detached and print JSON with url/streamUrl.
  list [device]   List running serve-sim streams as JSON.
  kill [device]   Stop serve-sim streams.

Examples:
  Tools/serve-sim-ios.sh doctor
  Tools/serve-sim-ios.sh start
  Tools/serve-sim-ios.sh kill
USAGE
}

serve_sim() {
  npx --yes "$SERVE_SIM_PACKAGE" "$@"
}

command="${1:-help}"
shift || true

case "$command" in
  doctor)
    uname -s
    xcrun --version
    node --version
    sw_vers -productVersion
    xcrun simctl list devices booted
    ;;
  start)
    serve_sim --detach -q "$@"
    ;;
  list)
    serve_sim --list -q "$@"
    ;;
  kill)
    serve_sim --kill "$@"
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
