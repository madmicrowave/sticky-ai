#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/Sticky-AI.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_PATH" "$PROJECT_ROOT/Sticky AI.app" "$PROJECT_ROOT/.build"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [ -d "$PROJECT_ROOT/Resources" ]; then
  cp -R "$PROJECT_ROOT"/Resources/* "$RESOURCES_DIR/" 2>/dev/null || true
fi

swiftc -O \
  "$PROJECT_ROOT"/Sources/StickyAICore/*.swift \
  "$PROJECT_ROOT"/Sources/StickyAIApp/main.swift \
  -framework AppKit \
  -framework WebKit \
  -framework Carbon \
  -o "$MACOS_DIR/StickyAI"

chmod +x "$MACOS_DIR/StickyAI"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Sticky-AI</string>
  <key>CFBundleDisplayName</key>
  <string>Sticky-AI</string>
  <key>CFBundleIdentifier</key>
  <string>com.domonk.sticky-ai</string>
  <key>CFBundleVersion</key>
  <string>2.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0.0</string>
  <key>CFBundleExecutable</key>
  <string>StickyAI</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

xattr -cr "$APP_PATH" 2>/dev/null || true
codesign --force --deep --sign - "$APP_PATH"

echo "Built standalone native macOS app: $APP_PATH"
