#!/usr/bin/env bash
# Builds Sonar.app (universal), embeds relayd and xray, ad-hoc signs everything.
# Output: dist/Sonar.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Sonar"
APP="$ROOT/dist/$APP_NAME.app"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

[[ "${SKIP_CORE_BUILD:-0}" == "1" && -x "$ROOT/bundle/relayd" ]] || "$ROOT/scripts/build-core.sh"
[[ -x "$ROOT/bundle/xray" ]] || "$ROOT/scripts/fetch-xray-vendor.sh"
if [[ ! -f "$ROOT/Sources/Sonar/Resources/Media/Sonar.icns" || "$ROOT/logo/sonar.png" -nt "$ROOT/Sources/Sonar/Resources/Media/Sonar.icns" ]]; then
  "$ROOT/scripts/make-icns.sh"
fi

echo "→ swift build (universal: arm64 + x86_64)"
swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64 --disable-sandbox 2>&1 | grep -E "error:|Build complete" || true
OUT="$ROOT/.build/out/Products/Release"
[[ -f "$OUT/$APP_NAME" ]] || OUT="$ROOT/.build/apple/Products/Release"
[[ -f "$OUT/$APP_NAME" ]] || { echo "error: swift build output not found" >&2; exit 1; }

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
lipo "$APP/Contents/MacOS/$APP_NAME" -verify_arch arm64 && lipo "$APP/Contents/MacOS/$APP_NAME" -verify_arch x86_64
cp "$ROOT/bundle/relayd" "$APP/Contents/Resources/SonarNet"
cp "$ROOT/bundle/xray"   "$APP/Contents/Resources/SonarCore"
chmod +x "$APP/Contents/Resources/SonarNet" "$APP/Contents/Resources/SonarCore"
for b in "$OUT"/*.bundle; do [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"; done
cp "$ROOT/Sources/Sonar/Resources/Media/Sonar.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.g3ntrix.sonar</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Sonar</string>
    <key>CFBundleDisplayName</key><string>Sonar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>Sonar</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Sonar: a private tunnel inside ping packets</string>
    <key>NSAppleEventsUsageDescription</key><string>Sonar opens Terminal with your SSH command ready to run.</string>
    <key>NSLocalNetworkUsageDescription</key><string>Sonar shares its proxy with your phone on the same Wi-Fi when you turn on Share to phone.</string>
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc by default. SONAR_SIGN_IDENTITY=<cert name> signs with a real identity instead.
SIGN_ID="${SONAR_SIGN_IDENTITY:--}"
if [[ "$SIGN_ID" == "-" ]]; then echo "→ ad-hoc signing (not notarized)"; else echo "→ signing with \"$SIGN_ID\" (not notarized)"; fi
ENT="$ROOT/scripts/entitlements.plist"
for bin in SonarNet SonarCore; do
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$APP/Contents/Resources/$bin"
done
codesign --force --sign "$SIGN_ID" --options runtime --entitlements "$ENT" --timestamp=none "$APP/Contents/MacOS/$APP_NAME"
codesign --force --sign "$SIGN_ID" --options runtime --entitlements "$ENT" --timestamp=none "$APP"
xattr -cr "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"
echo "✔ $APP ($VERSION, build $BUILD)"
