#!/usr/bin/env bash
# release.sh — builds LikhoLive, packages it as a .app, .zip, and .dmg
# Usage: ./scripts/release.sh [version]
# Example: ./scripts/release.sh 1.0.0

set -euo pipefail

VERSION="${1:-1.0.0}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCPROJECT="$PROJECT_DIR/LikhoLive/LikhoLive.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
RELEASE_DIR="$PROJECT_DIR/release"
APP_NAME="LikhoLive"

echo "==> LikhoLive release builder v$VERSION"
echo "    Project: $XCPROJECT"

# Clean
rm -rf "$BUILD_DIR" "$RELEASE_DIR"
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

# Build Release
echo "==> Building Release..."
xcodebuild \
  -project "$XCPROJECT" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | grep -v "appintentsmeta"

APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: .app not found at $APP_PATH"
  exit 1
fi

echo "==> App built: $APP_PATH"

# Set version in bundle
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_PATH/Contents/Info.plist"

# Create .zip
echo "==> Creating $APP_NAME-$VERSION.zip..."
ditto -c -k --keepParent "$APP_PATH" "$RELEASE_DIR/$APP_NAME-$VERSION.zip"

# Create .dmg
echo "==> Creating $APP_NAME-$VERSION.dmg..."
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

echo ""
echo "==> Release artifacts:"
ls -lh "$RELEASE_DIR/"
echo ""
echo "==> Done. To install: open $RELEASE_DIR/$APP_NAME-$VERSION.dmg"
echo "    First launch: right-click $APP_NAME.app → Open"
