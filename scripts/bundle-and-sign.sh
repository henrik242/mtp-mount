#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# (Re)sign MtpMount.app with Developer ID and the hardened runtime, inside-out,
# so it can be notarized. The agent talks to devices with IOUSBHost (a system
# framework), so the app has no third-party dylibs to bundle -- this just ships
# the license and re-signs with a secure timestamp.
#
# Usage:
#   scripts/bundle-and-sign.sh <app> [--timestamp]
#
# Configuration (environment variables, all optional):
#   SIGN_IDENTITY   Codesign identity. Default: the first "Developer ID
#                   Application" identity in the keychain.
#   AGENT_NAME      Helper executable name. Default: mtpmount-agent
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

# --- resolve configuration ------------------------------------------------
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
[ -n "${SIGN_IDENTITY:-}" ] || die "no Developer ID Application identity found; set SIGN_IDENTITY"

AGENT_NAME="${AGENT_NAME:-mtpmount-agent}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$APP/Contents/MacOS/$AGENT_NAME"
[ -x "$AGENT" ] || die "helper not found at $AGENT"
shopt -s nullglob
APPEXES=("$APP"/Contents/PlugIns/*.appex)
shopt -u nullglob
[ "${#APPEXES[@]}" -eq 1 ] || die "expected exactly one .appex in $APP/Contents/PlugIns, found ${#APPEXES[@]}"
APPEX="${APPEXES[0]}"

echo "==> Identity: $SIGN_IDENTITY"

echo "==> Checking architecture (arm64)"
for bin in "$AGENT" "$APP/Contents/MacOS/MtpMount"; do
    archs="$(lipo -archs "$bin")"
    [[ " $archs " == *" arm64 "* ]] || die "$bin has no arm64 slice ($archs)"
    echo "    $(basename "$bin"): $archs"
done

echo "==> Adding license text to Contents/Resources/Licenses"
LIC="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC"
cp "$REPO/LICENSE" "$LIC/LICENSE.txt"

echo "==> Code signing inside-out (Developer ID, hardened runtime)"
CS=(codesign --force --options runtime --sign "$SIGN_IDENTITY")
if [ "$TIMESTAMP" -eq 1 ]; then CS+=(--timestamp); echo "    (with secure timestamp)"; fi
"${CS[@]}" --entitlements "$REPO/Agent/Agent.entitlements" "$AGENT"
"${CS[@]}" --entitlements "$REPO/Extension/Extension.entitlements" "$APPEX"
"${CS[@]}" --entitlements "$REPO/App/App.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Done: $APP is signed."
