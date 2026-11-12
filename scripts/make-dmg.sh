#!/usr/bin/env bash
#
# Build a distributable disk image from a notarized MtpMount.app: a compressed
# DMG containing the app plus an /Applications drag-install target, signed with
# Developer ID and (optionally) notarized + stapled so it passes Gatekeeper
# offline when downloaded.
#
# Usage:
#   scripts/make-dmg.sh /path/to/MtpMount.app [out.dmg] [--notarize]
#
# Run scripts/bundle-and-sign.sh (with --timestamp) on the app first.
set -euo pipefail

APP="${1:?usage: make-dmg.sh /path/to/MtpMount.app [out.dmg] [--notarize]}"
OUT="${2:-MtpMount.dmg}"
NOTARIZE="${3:-}"
IDENTITY="Developer ID Application: Henrik Aronsen (358L7UXVJ4)"
VOLNAME="MtpMount"
KEY="$HOME/keystores/arbeit/AuthKey_NYDDY3JYA8.p8"
KEY_ID="NYDDY3JYA8"
ISSUER="cc24ec7f-7d96-4869-9420-90560e035d3a"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $OUT"
rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null

echo "==> Signing the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$OUT"

if [ "$NOTARIZE" = "--notarize" ]; then
    echo "==> Notarizing the DMG (waits for Apple)"
    xcrun notarytool submit "$OUT" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
    echo "==> Stapling"
    xcrun stapler staple "$OUT"
fi

echo "==> Verifying"
codesign -dv "$OUT" 2>&1 | grep -iE "Authority=Developer ID|Timestamp" | head -2 || true
spctl -a -t open --context context:primary-signature -vvv "$OUT" 2>&1 | head -5 || true
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
