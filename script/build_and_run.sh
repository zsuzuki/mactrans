#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MacTrans"
BUNDLE_ID="dev.local.MacTrans"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
INSTALLED_APP="$DIST_DIR/$APP_NAME.app"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
WHISPER_CPP_DIR="${WHISPER_CPP_DIR:-"$ROOT_DIR/../whisper.cpp"}"
WHISPER_BUILD="$WHISPER_CPP_DIR/build"

# TCC must see a certificate-based designated requirement that survives rebuilds.
# Linker ad-hoc signatures identify one binary hash and do not seal the .app.
SIGNING_IDENTITY="${MACTRANS_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  DEVELOPMENT_IDENTITIES=()
  while IFS= read -r identity; do
    DEVELOPMENT_IDENTITIES+=("$identity")
  done < <(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/ { print $2 }')
  if [[ ${#DEVELOPMENT_IDENTITIES[@]} -ne 1 ]]; then
    echo "Set MACTRANS_SIGNING_IDENTITY to an Apple Development certificate name or SHA-1; found ${#DEVELOPMENT_IDENTITIES[@]} candidates." >&2
    exit 1
  fi
  SIGNING_IDENTITY="${DEVELOPMENT_IDENTITIES[0]}"
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Ad-hoc signing loses recording permission across rebuilds. Use an Apple Development certificate." >&2
  exit 1
fi

cd "$ROOT_DIR"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.MacTrans-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp -R "$(dirname "$BUILD_BINARY")/MacTrans_MacTrans.bundle" "$APP_RESOURCES/"
chmod +x "$APP_BINARY"

cp "$WHISPER_BUILD/src"/libwhisper*.dylib "$APP_FRAMEWORKS/"
cp "$WHISPER_BUILD/ggml/src"/libggml*.dylib "$APP_FRAMEWORKS/"
cp "$WHISPER_BUILD/ggml/src/ggml-blas"/libggml-blas*.dylib "$APP_FRAMEWORKS/"
cp "$WHISPER_BUILD/ggml/src/ggml-metal"/libggml-metal*.dylib "$APP_FRAMEWORKS/"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacTrans records microphone audio to transcribe and translate speech locally.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign nested code first, then seal the bundle including its Info.plist.
for library in "$APP_FRAMEWORKS"/*.dylib; do
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$library"
done
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_RESOURCES/MacTrans_MacTrans.bundle"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --identifier "$BUNDLE_ID" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

# A build/signing failure above leaves the running app and previous bundle intact.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$INSTALLED_APP"
mv "$APP_BUNDLE" "$INSTALLED_APP"
APP_BUNDLE="$INSTALLED_APP"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
