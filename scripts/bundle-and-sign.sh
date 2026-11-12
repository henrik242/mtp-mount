#!/usr/bin/env bash
#
# Make MtpMount.app self-contained and (re)sign it with Developer ID so it can be
# notarized: copy libmtp + libusb into Contents/Frameworks, rewrite their link
# paths to @rpath, check they can load on the app's minimum macOS (arm64), and
# code-sign everything inside-out with the hardened runtime.
#
# Usage:
#   scripts/bundle-and-sign.sh <app> [--timestamp]
#
# Configuration (environment variables, all optional):
#   SIGN_IDENTITY   Codesign identity. Default: the first "Developer ID
#                   Application" identity in the keychain.
#   LIBMTP_DYLIB    Path to libmtp.9.dylib. Default: $(brew --prefix libmtp)/lib/libmtp.9.dylib
#   LIBUSB_DYLIB    Path to libusb-1.0.0.dylib. Default: what libmtp links, or
#                   $(brew --prefix libusb)/lib/libusb-1.0.0.dylib
#   AGENT_NAME      Helper executable name. Default: garmin-mtp-agent
#
# --timestamp adds a secure timestamp (needed for notarization; requires network).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

APP=""
TIMESTAMP=0
for arg in "$@"; do
    case "$arg" in
        --timestamp) TIMESTAMP=1 ;;
        -*) die "unknown option $arg" ;;
        *) [ -z "$APP" ] || die "unexpected argument $arg"; APP="$arg" ;;
    esac
done
[ -n "$APP" ] || die "usage: bundle-and-sign.sh <app> [--timestamp]"
[ -d "$APP" ] || die "no app at $APP"

brew_prefix() { brew --prefix "$1" 2>/dev/null || true; }

# --- resolve configuration ------------------------------------------------
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
[ -n "${SIGN_IDENTITY:-}" ] || die "no Developer ID Application identity found; set SIGN_IDENTITY"

LIBMTP_DYLIB="${LIBMTP_DYLIB:-$(brew_prefix libmtp)/lib/libmtp.9.dylib}"
[ -f "$LIBMTP_DYLIB" ] || die "libmtp not found at $LIBMTP_DYLIB (set LIBMTP_DYLIB)"
AGENT_NAME="${AGENT_NAME:-garmin-mtp-agent}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$APP/Contents/Frameworks"
AGENT="$APP/Contents/MacOS/$AGENT_NAME"
[ -x "$AGENT" ] || die "helper not found at $AGENT"
shopt -s nullglob
APPEXES=("$APP"/Contents/PlugIns/*.appex)
shopt -u nullglob
[ "${#APPEXES[@]}" -eq 1 ] || die "expected exactly one .appex in $APP/Contents/PlugIns, found ${#APPEXES[@]}"
APPEX="${APPEXES[0]}"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

echo "==> Identity: $SIGN_IDENTITY"
echo "==> Bundling dylibs into $FW"
mkdir -p "$FW"
cp -L "$LIBMTP_DYLIB" "$FW/libmtp.9.dylib"
LIBUSB_REF="$(otool -L "$FW/libmtp.9.dylib" | awk '/libusb/{print $1; exit}')"
[ -n "$LIBUSB_REF" ] || die "could not find libusb reference in libmtp"
if [ -z "${LIBUSB_DYLIB:-}" ]; then
    case "$LIBUSB_REF" in
        @*) LIBUSB_DYLIB="$(brew_prefix libusb)/lib/libusb-1.0.0.dylib" ;;  # already relative
        *)  LIBUSB_DYLIB="$LIBUSB_REF" ;;
    esac
fi
[ -f "$LIBUSB_DYLIB" ] || die "libusb not found at $LIBUSB_DYLIB (set LIBUSB_DYLIB)"
cp -L "$LIBUSB_DYLIB" "$FW/libusb-1.0.0.dylib"
chmod u+w "$FW/libmtp.9.dylib" "$FW/libusb-1.0.0.dylib"

echo "==> Rewriting install names to @rpath"
install_name_tool -id @rpath/libmtp.9.dylib     "$FW/libmtp.9.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib"
install_name_tool -change "$LIBUSB_REF" @rpath/libusb-1.0.0.dylib "$FW/libmtp.9.dylib"
AGENT_MTP_REF="$(otool -L "$AGENT" | awk '/libmtp/{print $1; exit}')"
[ -n "$AGENT_MTP_REF" ] || die "the helper doesn't link libmtp?"
install_name_tool -change "$AGENT_MTP_REF" @rpath/libmtp.9.dylib "$AGENT"

echo "==> Checking architecture and minimum macOS (app requires $MIN_OS, arm64)"
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
for bin in "$FW/libmtp.9.dylib" "$FW/libusb-1.0.0.dylib" "$AGENT"; do
    archs="$(lipo -archs "$bin")"
    [[ " $archs " == *" arm64 "* ]] || die "$bin has no arm64 slice ($archs)"
    minos="$(vtool -arch arm64 -show-build "$bin" | awk '/minos/{print $2; exit}')"
    [ -n "$minos" ] || die "could not read minos of $bin"
    version_le "$minos" "$MIN_OS" \
        || die "$(basename "$bin") needs macOS $minos but the app claims $MIN_OS; raise the deployment target"
    echo "    $(basename "$bin"): $archs, minos $minos"
done

echo "==> Code signing inside-out (Developer ID, hardened runtime)"
CS=(codesign --force --options runtime --sign "$SIGN_IDENTITY")
if [ "$TIMESTAMP" -eq 1 ]; then CS+=(--timestamp); echo "    (with secure timestamp)"; fi
"${CS[@]}" "$FW/libusb-1.0.0.dylib"
"${CS[@]}" "$FW/libmtp.9.dylib"
"${CS[@]}" --entitlements "$REPO/Agent/Agent.entitlements" "$AGENT"
"${CS[@]}" --entitlements "$REPO/Extension/Extension.entitlements" "$APPEX"
"${CS[@]}" --entitlements "$REPO/App/App.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "--- agent linkage ---"
otool -L "$AGENT" | grep -E "@rpath|libmtp|libusb" | sed 's/^/    /'
echo "==> Done: $APP is self-contained."
