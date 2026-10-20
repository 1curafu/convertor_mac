#!/usr/bin/env bash
# Builds build/Convertor.app with a static ffmpeg bundled inside.
#
#   scripts/build_app.sh              # build, downloading ffmpeg if needed
#   FFMPEG=/path/to/ffmpeg scripts/build_app.sh   # bundle a specific static ffmpeg
#   SKIP_FFMPEG=1 scripts/build_app.sh            # no bundled ffmpeg (falls back to Homebrew's)
#   scripts/build_app.sh --install    # also copy the app to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftUI's @State and friends are macros whose plugins ship only with the full Xcode app,
# so the standalone Command Line Tools fail with "plugin for module 'SwiftUIMacros' not found".
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  echo "✗ Xcode is required: the Command Line Tools can't compile SwiftUI apps."
  echo "  1. Install Xcode from the Mac App Store and open it once."
  echo "  2. sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "  3. Run this script again."
  exit 1
fi

APP=build/Convertor.app
CACHE=build/cache

echo "▸ Compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Convertor"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
cp "$BIN" "$APP/Contents/MacOS/Convertor"
cp scripts/Info.plist "$APP/Contents/Info.plist"

if [[ -z "${SKIP_FFMPEG:-}" ]]; then
  FFMPEG_SRC="${FFMPEG:-}"
  if [[ -z "$FFMPEG_SRC" ]]; then
    # Static builds (no Homebrew dylibs) from https://ffmpeg.martin-riedl.de
    case "$(uname -m)" in
      arm64) ARCH=arm64 ;;
      *) ARCH=amd64 ;;
    esac
    FFMPEG_SRC="$CACHE/ffmpeg-$ARCH"
    if [[ ! -x "$FFMPEG_SRC" ]]; then
      echo "▸ Downloading static ffmpeg ($ARCH)"
      curl -fL --retry 3 -o "$CACHE/ffmpeg.zip" \
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$ARCH/release/ffmpeg.zip"
      unzip -o -q "$CACHE/ffmpeg.zip" -d "$CACHE/ffmpeg-unzipped"
      mv "$CACHE/ffmpeg-unzipped/ffmpeg" "$FFMPEG_SRC"
      rm -rf "$CACHE/ffmpeg.zip" "$CACHE/ffmpeg-unzipped"
      chmod +x "$FFMPEG_SRC"
    fi
  fi
  echo "▸ Bundling ffmpeg from $FFMPEG_SRC"
  cp "$FFMPEG_SRC" "$APP/Contents/MacOS/ffmpeg"
  xattr -c "$APP/Contents/MacOS/ffmpeg" 2>/dev/null || true
  codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
fi

echo "▸ Signing (ad-hoc)"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications"
  pkill -x Convertor 2>/dev/null || true
  rm -rf /Applications/Convertor.app
  cp -R "$APP" /Applications/
  open /Applications/Convertor.app
fi

echo "✓ Done: $APP"
