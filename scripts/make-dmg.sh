#!/usr/bin/env bash
#
# Build a distributable disk image from a notarized MtpMount.app: a compressed
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

APP="${1:?usage: make-dmg.sh <app> [out.dmg] [--notarize]}"
OUT="${2:-$(basename "$APP" .app).dmg}"
NOTARIZE="${3:-}"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
[ -n "${SIGN_IDENTITY:-}" ] || { echo "error: no signing identity; set SIGN_IDENTITY" >&2; exit 1; }
VOLNAME="${VOLNAME:-$(basename "$APP" .app)}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $OUT"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null

echo "==> Signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT"

if [ "$NOTARIZE" = "--notarize" ]; then
    echo "==> Notarizing the DMG (waits for Apple)"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
        xcrun notarytool submit "$OUT" \
            --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    else
        echo "error: --notarize needs NOTARY_PROFILE or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER" >&2
        exit 1
    fi
    echo "==> Stapling"
    xcrun stapler staple "$OUT"
fi

echo "==> Verifying"
codesign -dv "$OUT" 2>&1 | grep -iE "Authority=Developer ID|Timestamp" | head -2 || true
spctl -a -t open --context context:primary-signature -vvv "$OUT" 2>&1 | head -5 || true
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
