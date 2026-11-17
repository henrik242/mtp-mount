#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Fail unless the app, the extension and the helper all carry the deployment
# target from project.yml, as Mach-O minos and LSMinimumSystemVersion.
#
# Usage:
#   scripts/check-min-os.sh <MtpMount.app>
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

APP="${1:-}"
[ -d "$APP" ] || die "usage: $0 <MtpMount.app>"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WANT="$(sed -n 's/^ *macOS: *"\([0-9.]*\)".*/\1/p' "$ROOT/project.yml" | head -1)"
[ -n "$WANT" ] || die "no deploymentTarget macOS in project.yml"

APPEX="$APP/Contents/PlugIns/MtpMountFileProvider.appex"
fail=0
for bin in "$APP/Contents/MacOS/MtpMount" \
           "$APP/Contents/MacOS/mtpmount-agent" \
           "$APPEX/Contents/MacOS/MtpMountFileProvider"; do
    got="$(vtool -show-build "$bin" | awk '/minos/ {print $2; exit}')"
    echo "$(basename "$bin"): minos $got"
    [ "$got" = "$WANT" ] || { echo "  expected $WANT" >&2; fail=1; }
done
for plist in "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"; do
    got="$(plutil -extract LSMinimumSystemVersion raw "$plist")"
    echo "$(basename "$(dirname "$(dirname "$plist")")"): LSMinimumSystemVersion $got"
    [ "$got" = "$WANT" ] || { echo "  expected $WANT" >&2; fail=1; }
done
exit "$fail"
