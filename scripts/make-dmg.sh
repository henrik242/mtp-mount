#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build a distributable disk image from a signed MtpMount.app: a compressed
# DMG containing the app plus an /Applications drag-install target, signed with
# Developer ID and (optionally) notarized + stapled so it passes Gatekeeper
# offline when downloaded.
#
# Usage:
#   scripts/make-dmg.sh <app> [out.dmg] [--notarize]
#
# Configuration (environment variables):
#   SIGN_IDENTITY    Codesign identity. Default: first "Developer ID Application".
#   VOLNAME          DMG volume name. Default: the app's base name.
#   Notarization (one of the two, required only with --notarize):
#     NOTARY_PROFILE                       notarytool keychain profile name, OR
#     NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER   ASC API key file + ids
#
# Run scripts/bundle-and-sign.sh (with --timestamp) on the app first.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

APP=""
OUT=""
NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        -*) die "unknown option $arg" ;;
        *)
            if [ -z "$APP" ]; then APP="$arg"
            elif [ -z "$OUT" ]; then OUT="$arg"
            else die "unexpected argument $arg"
            fi ;;
    esac
done
[ -n "$APP" ] || die "usage: make-dmg.sh <app> [out.dmg] [--notarize]"
[ -d "$APP" ] || die "no app at $APP"
OUT="${OUT:-$(basename "$APP" .app).dmg}"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
[ -n "${SIGN_IDENTITY:-}" ] || die "no signing identity; set SIGN_IDENTITY"
VOLNAME="${VOLNAME:-$(basename "$APP" .app)}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto preserves signatures, xattrs and symlinks inside the bundle.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "$REPO/LICENSE" "$STAGE/LICENSE.txt"

echo "==> Creating $OUT"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null

echo "==> Signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT"

if [ "$NOTARIZE" -eq 1 ]; then
    echo "==> Notarizing the DMG (waits for Apple)"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
        xcrun notarytool submit "$OUT" \
            --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    else
        die "--notarize needs NOTARY_PROFILE or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER"
    fi
    echo "==> Stapling"
    xcrun stapler staple "$OUT"
fi

echo "==> Verifying"
codesign -dv "$OUT" 2>&1 | grep -iE "Authority=Developer ID|Timestamp" | head -2 || true
if [ "$NOTARIZE" -eq 1 ]; then
    # A notarized release must pass Gatekeeper; fail the build if it doesn't.
    spctl -a -t open --context context:primary-signature -vv "$OUT"
else
    echo "    (not notarized: Gatekeeper check skipped)"
fi
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
