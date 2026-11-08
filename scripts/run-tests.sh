#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BIN="$(mktemp -t sticky-ai-tests-XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT

swiftc \
  "$PROJECT_ROOT"/Sources/StickyAICore/*.swift \
  "$PROJECT_ROOT"/Tests/TestMain.swift \
  -framework AppKit \
  -framework WebKit \
  -framework Carbon \
  -o "$TMP_BIN"

"$TMP_BIN"

