#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sticky-ai-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Embed LSUIElement=true directly into the test binary so macOS LaunchServices / Dock
# never displays `exec` icons in the bottom Dock or Recent Applications.
cat > "$BUILD_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.domonk.sticky-ai.tests</string>
  <key>CFBundleName</key>
  <string>StickyAITests</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

swiftc \
  "$PROJECT_ROOT"/Sources/StickyAICore/*.swift \
  "$PROJECT_ROOT"/Tests/TestMain.swift \
  -framework AppKit \
  -framework WebKit \
  -framework Carbon \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$BUILD_DIR/Info.plist" \
  -o "$BUILD_DIR/StickyAITests"

STICKY_AI_DISABLE_AUTO_LAUNCH_AGENT=1 STICKY_AI_HEADLESS_TEST=1 "$BUILD_DIR/StickyAITests"
