#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$SOURCE_ROOT/UsageButler.xcodeproj"
PBXPROJ_PATH="$PROJECT_PATH/project.pbxproj"
XCODEGEN_BIN="${XCODEGEN_BIN:-/opt/homebrew/bin/xcodegen}"

if [[ ! -x "$XCODEGEN_BIN" ]]; then
  XCODEGEN_BIN="$(command -v xcodegen)"
fi

"$XCODEGEN_BIN" generate --no-env --spec "$SOURCE_ROOT/project.yml" --project "$SOURCE_ROOT"
first_hash="$(shasum -a 256 "$PBXPROJ_PATH" | awk '{print $1}')"
"$XCODEGEN_BIN" generate --no-env --spec "$SOURCE_ROOT/project.yml" --project "$SOURCE_ROOT"
second_hash="$(shasum -a 256 "$PBXPROJ_PATH" | awk '{print $1}')"

if [[ "$first_hash" != "$second_hash" ]]; then
  echo "non-deterministic project generation: $first_hash != $second_hash" >&2
  exit 1
fi

echo "PBXPROJ_SHA256=$second_hash"
xcodebuild -list -project "$PROJECT_PATH"
