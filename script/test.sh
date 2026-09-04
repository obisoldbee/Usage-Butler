#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$SOURCE_ROOT/UsageButler.xcodeproj"
DERIVED_DATA_PATH="$SOURCE_ROOT/.build/DerivedData"
XCODEGEN_BIN="${XCODEGEN_BIN:-/opt/homebrew/bin/xcodegen}"

if [[ ! -x "$XCODEGEN_BIN" ]]; then
  XCODEGEN_BIN="$(command -v xcodegen)"
fi

"$XCODEGEN_BIN" generate --no-env --spec "$SOURCE_ROOT/project.yml" --project "$SOURCE_ROOT"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme UsageButler \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  test

