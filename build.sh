#!/bin/sh
# Builds build/Notchy.app: the SwiftPM executable, the vendored MediaRemoteAdapter.framework
# and its Perl launcher, Info.plist, and a code signature.
#
#   ./build.sh                       # host architecture, ad-hoc signed
#   UNIVERSAL=1 ./build.sh           # arm64 + x86_64 (needs full Xcode, not just the CLT)
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#                                    # hardened runtime + timestamp, ready for notarization
set -eu
cd "$(dirname "$0")"

VERSION=${VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
OUT=build
APP=$OUT/Notchy.app
MRA=Vendor/mediaremote-adapter

if [ "${UNIVERSAL:-0}" = 1 ]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
  CLANG_ARCHS="-arch arm64 -arch x86_64"
else
  ARCH_FLAGS=""
  CLANG_ARCHS="-arch $(uname -m)"
fi

echo "==> swift build"
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS --product Notchy
# shellcheck disable=SC2086
BIN_DIR=$(swift build -c release $ARCH_FLAGS --show-bin-path)

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Notchy" "$APP/Contents/MacOS/Notchy"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
# The icon is drawn by the app itself (SwiftUI), then packed with iconutil.
rm -rf "$OUT/AppIcon.iconset"
# (perl's alarm is a portable timeout: never let the build hang on it)
if perl -e 'alarm shift; exec @ARGV' 60 "$BIN_DIR/Notchy" --render-icon "$OUT/AppIcon.iconset" && iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  echo "    icon ok"
else
  echo "    (icon skipped)"
fi
cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/mediaremote-adapter-LICENSE.txt"

echo "==> MediaRemoteAdapter.framework"
# Upstream builds this with CMake; compiling directly avoids needing CMake installed.
# adapter/test.m (the `test` command) is skipped: it needs the test client we do not ship.
FW="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
mkdir -p "$FW/Versions/A/Resources"
# shellcheck disable=SC2086
clang -dynamiclib -fobjc-arc -fvisibility=default -O2 -w $CLANG_ARCHS -mmacosx-version-min=14.0 \
  -I "$MRA/include" -I "$MRA/src" \
  -framework Foundation -framework AppKit -framework ImageIO -framework CoreServices -framework UniformTypeIdentifiers \
  -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
  -current_version 0.1.0 -compatibility_version 0.1.0 \
  $(ls "$MRA"/src/adapter/*.m | grep -v '/test\.m$') "$MRA"/src/private/*.m "$MRA"/src/utility/*.m \
  -o "$FW/Versions/A/MediaRemoteAdapter"
cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FW/Resources"
cp "$MRA/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote-adapter.pl"

echo "==> codesign ($SIGN_IDENTITY)"
# Hardened runtime in both cases: without it, another process could start Notchy with
# DYLD_INSERT_LIBRARIES and run its code with the permissions granted to Notchy
# (Accessibility, Calendars, Automation).
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$FW"
  codesign --force --options runtime --entitlements Resources/Notchy.entitlements --sign - "$APP"
else
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$FW"
  codesign --force --timestamp --options runtime --entitlements Resources/Notchy.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "==> built $APP"
