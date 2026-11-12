#!/usr/bin/env bash
#
# Make MtpMount.app self-contained and (re)sign it with Developer ID so it can be
# notarized: copy libmtp + libusb into Contents/Frameworks, rewrite their link
# paths to @rpath, and code-sign everything inside-out with the hardened runtime.
#
# Usage:
#   scripts/bundle-and-sign.sh <app> [--timestamp]
#
# Configuration (environment variables, all optional):
#   SIGN_IDENTITY   Codesign identity. Default: the first "Developer ID
#                   Application" identity in the keychain.
#   LIBMTP_DYLIB    Path to libmtp.9.dylib. Default: $(brew --prefix)/lib/libmtp.9.dylib
#   AGENT_NAME      Helper executable name. Default: garmin-mtp-agent
#
# --timestamp adds a secure timestamp (needed for notarization; requires network).
set -euo pipefail

APP="${1:?usage: bundle-and-sign.sh <app> [--timestamp]}"
TS_FLAG="${2:-}"

# --- resolve configuration ------------------------------------------------
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
[ -n "${SIGN_IDENTITY:-}" ] || {
    echo "error: no Developer ID Application identity found; set SIGN_IDENTITY" >&2
    exit 1
}

LIBMTP_DYLIB="${LIBMTP_DYLIB:-$(brew --prefix 2>/dev/null)/lib/libmtp.9.dylib}"
[ -f "$LIBMTP_DYLIB" ] || { echo "error: libmtp not found at $LIBMTP_DYLIB (set LIBMTP_DYLIB)" >&2; exit 1; }
AGENT_NAME="${AGENT_NAME:-garmin-mtp-agent}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$APP/Contents/Frameworks"
AGENT="$APP/Contents/MacOS/$AGENT_NAME"
APPEX="$(ls -d "$APP"/Contents/PlugIns/*.appex 2>/dev/null | head -1)"
[ -x "$AGENT" ] || { echo "error: helper not found at $AGENT" >&2; exit 1; }

echo "==> Identity: $SIGN_IDENTITY"
echo "==> Bundling dylibs into $FW"
mkdir -p "$FW"
cp -L "$LIBMTP_DYLIB" "$FW/libmtp.9.dylib"
LIBUSB_REF="$(otool -L "$FW/libmtp.9.dylib" | awk '/libusb/{print $1; exit}')"
[ -n "$LIBUSB_REF" ] || { echo "error: could not find libusb reference in libmtp" >&2; exit 1; }
cp -L "$LIBUSB_REF" "$FW/libusb-1.0.0.dylib"
chmod u+w "$FW/libmtp.9.dylib" "$FW/libusb-1.0.0.dylib"

echo "==> Rewriting install names to @rpath"
install_name_tool -id @rpath/libmtp.9.dylib     "$FW/libmtp.9.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib"
install_name_tool -change "$LIBUSB_REF" @rpath/libusb-1.0.0.dylib "$FW/libmtp.9.dylib"
AGENT_MTP_REF="$(otool -L "$AGENT" | awk '/libmtp/{print $1; exit}')"
install_name_tool -change "$AGENT_MTP_REF" @rpath/libmtp.9.dylib "$AGENT"

echo "==> Code signing inside-out (Developer ID, hardened runtime)"
CS=(codesign --force --options runtime --sign "$SIGN_IDENTITY")
if [ "$TS_FLAG" = "--timestamp" ]; then CS+=(--timestamp); echo "    (with secure timestamp)"; fi
"${CS[@]}" "$FW/libusb-1.0.0.dylib"
"${CS[@]}" "$FW/libmtp.9.dylib"
"${CS[@]}" --entitlements "$REPO/Agent/Agent.entitlements" "$AGENT"
[ -n "$APPEX" ] && "${CS[@]}" --entitlements "$REPO/Extension/Extension.entitlements" "$APPEX"
"${CS[@]}" --entitlements "$REPO/App/App.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "--- agent linkage ---"
otool -L "$AGENT" | grep -E "@rpath|libmtp|libusb" | sed 's/^/    /'
echo "==> Done: $APP is self-contained."
