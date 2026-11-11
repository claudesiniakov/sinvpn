#!/usr/bin/env bash
# Собирает SinVpn.app (arm64) из Swift-пакета и упаковывает в build/SinVpn.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

# Версия — из последнего тега vX.Y.Z, номер сборки — число коммитов.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/SinVpn.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SinVpn"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SinVpn"

# Иконка: Resources/AppIcon.png (1024×1024, рисует scripts/make-icon.py) → AppIcon.icns
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SinVpn</string>
  <key>CFBundleDisplayName</key><string>SinVpn</string>
  <key>CFBundleIdentifier</key><string>com.claudesiniakov.sinvpn</string>
  <key>CFBundleExecutable</key><string>SinVpn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© claudesiniakov</string>
</dict>
</plist>
PLIST

# Ad-hoc подпись (без Developer ID). Для распространения нужна подпись и нотаризация.
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --verbose "$APP"

ditto -c -k --keepParent "$APP" build/SinVpn.zip
# Контрольная сумма для проверки обновления внутри приложения.
(cd build && shasum -a 256 SinVpn.zip > SinVpn.zip.sha256)
echo "Готово: $APP и build/SinVpn.zip (версия $VERSION, сборка $BUILD_NUMBER)"
