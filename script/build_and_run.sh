#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--panel|--fixture-panel|--network-panel]" >&2
  exit 2
fi

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--panel|--fixture-panel|--network-panel) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--panel|--fixture-panel|--network-panel]" >&2
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

owned_pids() {
  local candidate
  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ "$(ps -p "$candidate" -o comm=)" == "$APP_BINARY" ]]; then echo "$candidate"; fi
  done < <(pgrep -x "$APP_NAME" || true)
}
OLD_PIDS="$(owned_pids)"

stop_running_app() {
  local owned
  local child child_start i
  local children=() child_starts=()
  for owned in $OLD_PIDS; do
    while read -r child; do
      [[ -n "$child" ]] || continue
      children+=("$child")
      child_starts+=("$(ps -p "$child" -o lstart=)")
    done < <(ps -axo pid=,ppid=,comm= | awk -v parent="$owned" '$2 == parent && $3 == "/usr/bin/nettop" {print $1}')
  done
  for owned in $OLD_PIDS; do kill -TERM "$owned"; done
  # SIGTERM skips AppKit's graceful quit. Retire only the exact children
  # captured under this build, with executable and start-time rechecks.
  for ((i=0; i<${#children[@]}; i++)); do
    child="${children[$i]}"; child_start="${child_starts[$i]}"
    if [[ "$(ps -p "$child" -o comm=)" == /usr/bin/nettop && "$(ps -p "$child" -o lstart=)" == "$child_start" ]]; then
      kill -TERM "$child"
    fi
  done

  local attempt
  for attempt in {1..20}; do
    if [[ -z "$(owned_pids)" ]]; then
      local child_running=false
      for ((i=0; i<${#children[@]}; i++)); do
        child="${children[$i]}"; child_start="${child_starts[$i]}"
        if [[ "$(ps -p "$child" -o comm=)" == /usr/bin/nettop && "$(ps -p "$child" -o lstart=)" == "$child_start" ]]; then
          child_running=true
        fi
      done
      if [[ "$child_running" == false ]]; then return; fi
    fi
    sleep 0.1
  done

  echo "$APP_NAME or its owned nettop did not stop before rebuild" >&2
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
    pid="$(owned_pids | tail -n 1)"
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
  --network-panel)
    /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
    validation_args=(--show-panel-for-validation --network-v2-window)
    if [[ -n "${USAGE_BUTLER_VALIDATION_RECORDS:-}" ]]; then
      validation_args+=("--network-validation-records=$USAGE_BUTLER_VALIDATION_RECORDS")
    fi
    /usr/bin/open -n --env USAGE_BUTLER_NETWORK_VALIDATION=1 "$APP_BUNDLE" --args "${validation_args[@]}"
    verify_process
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
