#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/portal-high-bitrate-build"
ICON_TMP_DIR="/tmp/portal-high-bitrate-icons"
APP_NAME="Portal-High-Bitrate"

VERSION_FILE="$HERE/VERSION"
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
IFS='.' read -r major minor patch <<< "$VERSION"
BUILD_NUM="${patch:-1}"
if [ "$BUILD_NUM" = "0" ]; then
    BUILD_NUM="1"
fi

BUNDLE_DIR="$HERE/build/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "⚡️ 正在编译 $APP_NAME v$VERSION (Build $BUILD_NUM, Universal: arm64 + x86_64)..."

TMPDIR=/tmp \
DARWIN_USER_TEMP_DIR=/tmp \
DARWIN_USER_CACHE_DIR=/tmp \
CLANG_MODULE_CACHE_PATH=/tmp/clang-cache \
/Library/Developer/CommandLineTools/usr/bin/swift build \
    --package-path "$HERE" \
    --scratch-path "$BUILD_DIR" \
    --disable-sandbox \
    -c release \
    --arch arm64 \
    --arch x86_64 \
    -Xswiftc -module-cache-path -Xswiftc /tmp/clang-cache

BIN_DIR=$(TMPDIR=/tmp DARWIN_USER_TEMP_DIR=/tmp DARWIN_USER_CACHE_DIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/clang-cache /Library/Developer/CommandLineTools/usr/bin/swift build --package-path "$HERE" --scratch-path "$BUILD_DIR" --show-bin-path -c release --arch arm64 --arch x86_64)
BIN_PATH="$BIN_DIR/$APP_NAME"

echo "📦 正在组装 Universal 应用包 ($APP_NAME.app)..."
rm -rf "$BUNDLE_DIR" "$ICON_TMP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICON_TMP_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

/usr/bin/clang -O2 -Wall -Wextra -arch arm64 -arch x86_64 \
    "$HERE/scripts/portal_engine.c" \
    -o "$RESOURCES_DIR/portal_engine"
chmod 755 "$RESOURCES_DIR/portal_engine"
if [ -f "$HERE/Resources/manifest.json" ]; then
    cp "$HERE/Resources/manifest.json" "$RESOURCES_DIR/manifest.json"
fi

echo "🔍 校验通用二进制架构:"
/usr/bin/lipo -info "$MACOS_DIR/$APP_NAME"
/usr/bin/lipo -info "$RESOURCES_DIR/portal_engine"

echo "🎨 正在生成应用图标 (AppIcon.icns)..."
"$MACOS_DIR/$APP_NAME" --generate-icons "$ICON_TMP_DIR"
/usr/bin/iconutil -c icns "$ICON_TMP_DIR/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"

cat << EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.rabbit.portal-high-bitrate</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUM</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Portal-High-Bitrate 需要访问局域网以扫描 PS5 / PS Portal 设备并执行局域网串流码率增强。</string>
</dict>
</plist>
EOF

echo "🔐 正在进行代码签名与完整性校验..."
/usr/bin/xattr -cr "$BUNDLE_DIR"
/usr/bin/codesign --force -s - -i "com.rabbit.portal-high-bitrate.engine" "$RESOURCES_DIR/portal_engine"
/usr/bin/codesign --force -s - -r='designated => identifier "com.rabbit.portal-high-bitrate"' "$BUNDLE_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUNDLE_DIR"

mkdir -p "$HERE/../build"
rm -rf "$HERE/../build/$APP_NAME.app"
cp -R "$BUNDLE_DIR" "$HERE/../build/$APP_NAME.app"
/usr/bin/codesign --verify --deep --strict "$HERE/../build/$APP_NAME.app"

echo "💿 正在打包通用版 DMG ($APP_NAME-v$VERSION.dmg)..."
DMG_STAGING="/tmp/portal-high-bitrate-dmg"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$BUNDLE_DIR" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_OUTPUT="$HERE/../build/$APP_NAME-v$VERSION.dmg"
rm -f "$DMG_OUTPUT"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_OUTPUT" -quiet
/usr/bin/xattr -c "$DMG_OUTPUT" 2>/dev/null || true
rm -rf "$DMG_STAGING"

echo "🚀 正在启动 $APP_NAME.app..."
/usr/bin/killall -TERM "$APP_NAME" 2>/dev/null || true
sleep 0.3
/usr/bin/open "$HERE/../build/$APP_NAME.app"

echo "✅ 打包完成:"
echo "   - 独立 App: $HERE/../build/$APP_NAME.app"
echo "   - 通用 DMG: $DMG_OUTPUT"
