# mtp-mount

Mount any device that exposes its storage over **MTP over USB** — Android
phones, GPS units, cameras, music players, e-readers — as a browsable macOS
volume, using Apple's **File Provider** API. No kernel
extension, no reboot: the device appears in Finder's sidebar (under Locations)
and under `~/Library/CloudStorage/`, and is usable from the Terminal (`ls`, `cp`,
`rsync`). The device I/O is a self-contained PTP/MTP implementation over Apple's
**IOUSBHost** — no libmtp, no third-party dependencies.

Requires an Apple Silicon Mac on the latest macOS.

## Quick start

1. Download the latest `MtpMount-x.y.z.dmg` from the
   [Releases](../../releases) page, open it and drag **MtpMount** to
   **Applications**. (It must run from Applications.)
2. Open MtpMount from Applications. It installs a small helper.
3. If the window says so, turn on the extension: **System Settings → General →
   Login Items & Extensions → File Providers → MtpMount** (the window has a
   button that opens the right page).
4. Connect the device with a USB data cable and unlock it. On an Android phone,
   tap the USB notification and choose **File transfer**. The device appears
   in the window and in Finder's sidebar under its own name (e.g. "Galaxy
   S25"). "Show in Finder" opens it.

You can copy files off the device, copy files onto it, and create, rename, move
and delete files and folders. Changes made on the device while it's connected
(a new photo, say) show up in Finder within a few seconds. Several devices can
be connected at once; each gets its own location. Cameras are left alone (for
Photos and Image Capture): a device whose storage is all in the camera file
system (DCF) is released right away. A device's location is removed when you
unplug it and reappears when you reconnect. Editing a file in place on the device isn't
possible (MTP has no partial writes): copy it to your Mac, edit it, copy it back.

### Troubleshooting

- **"Device is in use by another app"** — macOS and other tools grab MTP
  devices. Quit Android File Transfer, OpenMTP and any sync app from the
  device's maker. If Image Capture or Photos opens when you plug the device
  in, open Image Capture, select the device and set "Connecting this device
  opens" to **No application**. Then unplug and reconnect.
- **"No device connected"** although it's plugged in — use a data cable (not a
  charge-only one), unlock the device, on a phone choose **File transfer** in
  the USB notification, and try another port/cable.
- **The device doesn't appear in Finder** — make sure the extension is
  enabled (step 3), open MtpMount once with the device attached, then use
  **Troubleshooting → Reset** in the window if it's still missing.
- **"The MtpMount helper isn't running"** — **Troubleshooting → Reinstall helper**.
- **Finder shows stale contents** — **Troubleshooting → Refresh Finder**.

### Uninstall

Open MtpMount, choose **Troubleshooting → Uninstall…**, then move MtpMount to
the Trash. (That removes the helper's LaunchAgent,
`~/Library/LaunchAgents/no.synth.mtpmount.helper.plist`, and the Finder
locations.)

## Architecture

```
MtpMount.app                        container app (NOT sandboxed) — registers the
  │                                 File Provider domain and installs the helper
  ├─ Contents/PlugIns/
  │    MtpMountFileProvider.appex    sandboxed replicated File Provider extension;
  │                                  all device I/O goes over XPC to the helper
  └─ Contents/MacOS/
       mtpmount-agent               non-sandboxed helper owning the IOUSBHost
                                    USB session; vends a launchd mach XPC service
```

The app installs the helper as a per-user LaunchAgent
(`~/Library/LaunchAgents/no.synth.mtpmount.helper.plist`) and `launchctl
bootstrap`s it; launchd then starts it on demand when the extension looks up its
mach service. (We drive launchd directly instead of `SMAppService` because BTM
refuses to let an app register a non-sandboxed helper.)

The helper reads MTP folders on demand (`GetObjectHandles` + `GetObjectInfo`,
uncached) for enumeration, and for a file download streams the object
(`GetObject`/`GetPartialObject`) into a file descriptor the sandboxed extension
passes over XPC (uploads work the same way in reverse with `SendObject`), with
byte progress and cancellation carried by `NSProgress` across the connection.

Each attached device gets its own File Provider domain, identified by the
device's USB serial number and named after the device. The helper opens every
attached MTP device (watching USB hotplug via IOKit) and every request names
its device. When a new device appears the helper adds its domain — or, if the
system doesn't let the helper do that, starts the app in the background
(`--sync-domains`) to add it.

MTP object handles are only valid within one USB session, so a domain's sync
anchor is the device's serial plus a session id, plus a position in a journal
of the MTP events the device sends (object added/removed), which the helper
polls once a second. Changes made on the device while it's connected are
reported to Finder item by item; a new session means a full re-enumeration.
Operations that change an existing item first check it still matches the
version Finder based the change on.

## Build

Requires an Apple Silicon Mac with the latest Xcode,
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and
an Apple Developer account signed into Xcode. The agent talks to devices with
IOUSBHost (a system framework), so there are no third-party dependencies to
install or bundle.

```sh
xcodegen generate
xcodebuild -project MtpMount.xcodeproj -scheme MtpMount -configuration Debug \
  -derivedDataPath build build
```

The Xcode project is generated from `project.yml` and is git-ignored.

## Install & run (local)

```sh
cp -R build/Build/Products/Debug/MtpMount.app /Applications/   # must run from /Applications
open /Applications/MtpMount.app                                # registers the domain
```

Then **enable the extension**: System Settings → General → Login Items &
Extensions → File Providers → MtpMount. (Apps installed outside the App Store
register their providers disabled, pending approval.)

The volume then appears in Finder's sidebar and under `~/Library/CloudStorage/`.

## Packaging & notarization

Two scripts under `scripts/` do the packaging. Both are configured by environment
variables with sensible defaults (they auto-detect the Developer ID identity), so
they carry no machine-specific paths.

`scripts/bundle-and-sign.sh <app> [--timestamp]` ships the license and re-signs
everything inside-out with Developer ID and the hardened runtime (with a secure
timestamp for notarization). There are no third-party dylibs to bundle. Config:
`SIGN_IDENTITY`, `AGENT_NAME`.

`scripts/make-dmg.sh <app> [out.dmg] [--notarize]` wraps the app in a compressed
DMG with an `/Applications` drag-install target, signs it, and — with
`--notarize` — notarizes and staples the DMG. Config: `SIGN_IDENTITY`, `VOLNAME`,
and for notarization either `NOTARY_PROFILE` (a `notarytool store-credentials`
profile) or `NOTARY_KEY` + `NOTARY_KEY_ID` + `NOTARY_ISSUER` (an ASC API key).

```sh
xcodebuild -project MtpMount.xcodeproj -scheme MtpMount -configuration Release \
  -derivedDataPath build-release build
APP=build-release/Build/Products/Release/MtpMount.app

scripts/bundle-and-sign.sh "$APP" --timestamp

export NOTARY_KEY=/path/to/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid>
scripts/make-dmg.sh "$APP" dist/MtpMount-0.2.3.dmg --notarize
```

The result passes `spctl -a -t open --context context:primary-signature` and is
ready to hand out.

## Continuous integration

`.github/workflows/ci.yml`:

- **build** — on every push/PR, installs XcodeGen and does an *unsigned*
  compile check (no secrets involved).
- **release** — on a `v*` tag, builds Release, runs the two scripts to produce a
  signed, notarized, stapled DMG, and attaches it to the GitHub Release. It runs
  only when the signing secrets are present, and imports them into a temporary
  keychain that is deleted afterward (nothing is written to the repo or logs).

Required repository secrets for the release job:

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | base64 of the Developer ID Application cert + key (`.p12`) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
| `PROVISIONING_PROFILE_APP_BASE64` | base64 of the app's `.provisionprofile` |
| `PROVISIONING_PROFILE_EXT_BASE64` | base64 of the extension's `.provisionprofile` |
| `NOTARY_KEY_P8_BASE64` | base64 of the ASC API key (`.p8`) |
| `NOTARY_KEY_ID` / `NOTARY_ISSUER` | ASC API key id and issuer UUID |

Base64 a file with `base64 -i file -o -` (or `base64 < file`). The jobs run on
an Apple Silicon runner (`macos-26`).

## Signing notes

Uses Developer ID manual signing (team `358L7UXVJ4`) against provisioning profiles
created via the App Store Connect API. A File Provider extension **requires**
provisioning profiles (for `com.apple.application-identifier`); bare
Developer ID signing without a profile fails. The container app is **not**
sandboxed (so it can install the helper LaunchAgent directly); only the extension
is sandboxed, as the system requires. A different developer/team must change the
team id and `no.synth.mtpmount*` bundle ids in `project.yml`, the `*.entitlements`
files, and `Shared/*.swift` (`MtpAgentConfig.teamID`).

The helper only accepts XPC connections from the extension and the app signed
by this team (and the extension only talks to a helper signed by it), so
unsigned or differently-signed local builds can't talk to each other.

## License

MtpMount is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version. See [`LICENSE`](LICENSE).

The app has no third-party runtime dependencies; it talks to devices with
Apple's IOUSBHost framework. The license text is shipped inside the app
(`Contents/Resources/Licenses`).
