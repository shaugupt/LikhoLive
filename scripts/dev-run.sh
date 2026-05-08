#!/bin/bash
# dev-run.sh — Build, install to /Applications, and launch LikhoLive
# Run this instead of Xcode's Cmd+R to keep a stable binary path.
# Accessibility + Keychain permissions persist across runs this way.
#
# Usage: ./scripts/dev-run.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PROJECT="$ROOT/LikhoLive/LikhoLive.xcodeproj"
APP_NAME="LikhoLive"
INSTALL_PATH="/Applications/$APP_NAME.app"
BUILD_DIR="/tmp/LikhoLive-dev-build"

echo "==> Killing any running instance..."
pkill -x LikhoLive 2>/dev/null || true
sleep 0.5

echo "==> Building Debug..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | grep -v "warning: Metadata"

BUILT_APP="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"

if [ ! -d "$BUILT_APP" ]; then
  echo "ERROR: Build output not found at $BUILT_APP"
  exit 1
fi

echo "==> Signing with ad-hoc identity..."
codesign --force --deep --sign - \
  --entitlements "$ROOT/LikhoLive/LikhoLive/Resources/LikhoLive.entitlements" \
  "$BUILT_APP"

echo "==> Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$BUILT_APP" "$INSTALL_PATH"

echo "==> Launching..."
open "$INSTALL_PATH"

echo ""
echo "✓ LikhoLive running from $INSTALL_PATH"
echo "  Accessibility + Keychain permissions will persist across runs."
echo "  To view logs: log stream --predicate 'process == \"LikhoLive\"' --level debug"
