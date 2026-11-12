#!/usr/bin/env bash
#
# Make MtpMount.app self-contained and (re)sign it with Developer ID so it can be
# notarized: copy libmtp + libusb into Contents/Frameworks, rewrite their link
# paths to @rpath, and code-sign everything inside-out with the hardened runtime.
#
# Usage:
#   scripts/bundle-and-sign.sh /path/to/MtpMount.app [--timestamp]
#
# Pass --timestamp for a notarization-ready signature (needs network; contacts
# Apple's secure timestamp server). Omit it for fast local iteration.
set -euo pipefail

APP="${1:?usage: bundle-and-sign.sh /path/to/MtpMount.app [--timestamp]}"
TS_FLAG="${2:-}"
IDENTITY="Developer ID Application: Henrik Aronsen (358L7UXVJ4)"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$APP/Contents/Frameworks"
AGENT="$APP/Contents/MacOS/garmin-mtp-agent"
APPEX="$APP/Contents/PlugIns/MtpMountFileProvider.appex"
BREW_LIB="$(brew --prefix)/lib"

echo "==> Bundling dylibs into $FW"
mkdir -p "$FW"
# Follow symlinks (-L) to copy the real dylib files.
cp -L "$BREW_LIB/libmtp.9.dylib" "$FW/libmtp.9.dylib"
LIBUSB_REF="$(otool -L "$FW/libmtp.9.dylib" | awk '/libusb/{print $1; exit}')"
cp -L "$LIBUSB_REF" "$FW/libusb-1.0.0.dylib"
chmod u+w "$FW/libmtp.9.dylib" "$FW/libusb-1.0.0.dylib"

echo "==> Rewriting install names to @rpath"
install_name_tool -id @rpath/libmtp.9.dylib    "$FW/libmtp.9.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib"
# libmtp's reference to libusb -> @rpath
install_name_tool -change "$LIBUSB_REF" @rpath/libusb-1.0.0.dylib "$FW/libmtp.9.dylib"
# the agent's reference to libmtp -> @rpath
AGENT_MTP_REF="$(otool -L "$AGENT" | awk '/libmtp/{print $1; exit}')"
install_name_tool -change "$AGENT_MTP_REF" @rpath/libmtp.9.dylib "$AGENT"

echo "==> Code signing inside-out (Developer ID, hardened runtime)"
CS=(codesign --force --options runtime --sign "$IDENTITY")
if [ "$TS_FLAG" = "--timestamp" ]; then CS+=(--timestamp); echo "    (with secure timestamp)"; fi
"${CS[@]}" "$FW/libusb-1.0.0.dylib"
"${CS[@]}" "$FW/libmtp.9.dylib"
"${CS[@]}" --entitlements "$REPO/Agent/Agent.entitlements"       "$AGENT"
"${CS[@]}" --entitlements "$REPO/Extension/Extension.entitlements" "$APPEX"
"${CS[@]}" --entitlements "$REPO/App/App.entitlements"          "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "--- agent linkage ---"
otool -L "$AGENT" | grep -E "@rpath|libmtp|libusb" | sed 's/^/    /'
echo "--- rpaths ---"
otool -l "$AGENT" | awk '/LC_RPATH/{f=1} f&&/path /{print "    "$2; f=0}'
echo "==> Done: $APP is self-contained."
