#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--panel|--fixture-panel]" >&2
  exit 2
fi

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--panel|--fixture-panel) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--panel|--fixture-panel]" >&2
    exit 2
    ;;
esac

APP_NAME="Usage-Butler"
BUNDLE_ID="io.github.obisoldbee.UsageButler"
SCHEME="UsageButler"
CONFIGURATION="Debug"

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$SOURCE_ROOT/UsageButler.xcodeproj"
DERIVED_DATA_PATH="$SOURCE_ROOT/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

resolve_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    command -v xcodegen
    return
  fi
  if [[ -x /opt/homebrew/bin/xcodegen ]]; then
    echo /opt/homebrew/bin/xcodegen
    return
  fi
  if [[ -x /usr/local/bin/xcodegen ]]; then
    echo /usr/local/bin/xcodegen
    return
  fi
  echo "xcodegen is required" >&2
  return 1
}

XCODEGEN_BIN="$(resolve_xcodegen)"
command -v xcodebuild >/dev/null
command -v pgrep >/dev/null
command -v pkill >/dev/null
[[ -f "$SOURCE_ROOT/project.yml" ]]

OLD_PIDS="$(pgrep -x "$APP_NAME" || true)"

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true

  local attempt
  for attempt in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done

  echo "$APP_NAME did not stop before rebuild" >&2
  return 1
}

generate_project() {
  "$XCODEGEN_BIN" generate \
    --no-env \
    --spec "$SOURCE_ROOT/project.yml" \
    --project "$SOURCE_ROOT"
}

build_app() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build
  [[ -x "$APP_BINARY" ]]
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
  local pid=""
  local attempt
  for attempt in {1..20}; do
    pid="$(pgrep -x "$APP_NAME" | tail -n 1 || true)"
    if [[ -n "$pid" ]]; then
      break
    fi
    sleep 0.25
  done

  if [[ -z "$pid" ]]; then
    echo "$APP_NAME did not remain running after launch" >&2
    return 1
  fi

  if [[ -n "$OLD_PIDS" ]] && grep -qx "$pid" <<<"$OLD_PIDS"; then
    echo "launch reused an old still-running PID: $pid" >&2
    return 1
  fi

  local executable_path
  executable_path="$(ps -p "$pid" -o comm= | sed 's/^[[:space:]]*//')"
  if [[ "$executable_path" != "$APP_BINARY" ]]; then
    echo "unexpected executable path: $executable_path" >&2
    return 1
  fi

  local plist="$APP_BUNDLE/Contents/Info.plist"
  local actual_bundle_id
  local short_version
  local build_version
  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  [[ "$actual_bundle_id" == "$BUNDLE_ID" ]]

  echo "PID=$pid"
  echo "BUNDLE_PATH=$APP_BUNDLE"
  echo "EXECUTABLE_PATH=$executable_path"
  echo "BUNDLE_ID=$actual_bundle_id"
  echo "VERSION=$short_version"
  echo "BUILD=$build_version"
}

stop_running_app
generate_project
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --fixture-panel)
    /usr/bin/open -n --env USAGE_BUTLER_OFFLINE_FIXTURE=1 "$APP_BUNDLE" --args --show-panel-for-validation --network-v2-preview --network-v2-window
    verify_process
    ;;
  --panel)
    /usr/bin/open -n "$APP_BUNDLE" --stdout "$SOURCE_ROOT/.build/panel-validation.stdout.log" --stderr "$SOURCE_ROOT/.build/panel-validation.stderr.log" --args --show-panel-for-validation
    verify_process
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
esac
