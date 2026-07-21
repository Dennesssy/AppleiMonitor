#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.derivedData"
APP_NAME="AppleiMonitor"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
xcodebuild -project "$ROOT_DIR/AppleiMonitor.xcodeproj" -scheme AppleiMonitor -configuration Debug -derivedDataPath "$DERIVED_DATA" build

case "$MODE" in
  run) /usr/bin/open -n "$APP_PATH" ;;
  --debug|debug) lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME" ;;
  --logs|logs) /usr/bin/open -n "$APP_PATH"; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP_PATH"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.dennesssy.AppleiMonitor"' ;;
  --verify|verify) /usr/bin/open -n "$APP_PATH"; sleep 2; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
