# mtp-mount

Mount any device that exposes its storage over **MTP over USB** (Android
phones, GPS units, cameras, music players, e-readers) as a browsable macOS
volume, using Apple's **File Provider** API. No kernel extension, no reboot:
the device appears in Finder's sidebar under Locations and under
`~/Library/CloudStorage/`, and works from the Terminal (`ls`, `cp`, `rsync`).
Device I/O is a self-contained PTP/MTP implementation over Apple's
**IOUSBHost**, with no libmtp and no third-party dependencies.

Requires an Apple Silicon Mac on the latest macOS.

## Install

```sh
brew install --cask henrik242/brew/mtp-mount
```

Or download `MtpMount-x.y.z.dmg` from [Releases](../../releases/latest) and
drag **MtpMount** to **Applications** (it must run from there).

1. Open MtpMount. It installs a small helper and lives in the menu bar.
2. Turn on the extension (macOS registers it disabled, and only you can enable
   it): **System Settings → General → Login Items & Extensions**, find
   MtpMount under **Extensions**, click ⓘ and switch on **File Provider**. On
   some macOS versions it's under a **File Providers** category instead. The
   app's window has a button that opens the right pane.
3. Connect the device with a USB data cable and unlock it. On an Android
   phone, tap the USB notification and choose **File transfer**. The device
   appears in the window and in Finder's sidebar under its own name (e.g.
   "Galaxy S25").

## Usage

Copy files on and off the device, and create, rename, move and delete files
and folders. Changes made on the device while it's connected show up in Finder
within a few seconds.

- Several devices can be connected at once; each gets its own location.
- A device's location is removed on unplug and comes back on reconnect.
- Cameras are left to Photos and Image Capture: a device whose storage is all
  camera file system (DCF) is released right away.
- No in-place edits (MTP has no partial writes): copy the file to your Mac,
  edit it, copy it back.

### Troubleshooting

- **"Device is in use by another app"**: quit Android File Transfer, OpenMTP
  and any maker's sync app. If Image Capture or Photos opens when you plug the
  device in, open Image Capture, select the device and set "Connecting this
  device opens" to **No application**. Then reconnect.
- **"No device connected"** although it's plugged in: use a data cable (not
  charge-only), unlock the device, choose **File transfer** on a phone, and
  try another port or cable.
- **The device doesn't appear in Finder**: check the extension is enabled,
  open MtpMount with the device attached, then try **Troubleshooting → Reset**.
- **"The MtpMount helper isn't running"**: **Troubleshooting → Reinstall helper**.
- **Finder shows stale contents**: **Troubleshooting → Refresh Finder**.

### Uninstall

Open MtpMount and choose **Troubleshooting → Uninstall…** (removes the helper's
LaunchAgent, `~/Library/LaunchAgents/no.synth.mtpmount.helper.plist`, and the
Finder locations). Then run `brew uninstall --cask mtp-mount`, or move the app
to the Trash.

## Architecture

```
MtpMount.app                        container app (NOT sandboxed): registers the
  │                                 File Provider domain and installs the helper
  ├─ Contents/PlugIns/
  │    MtpMountFileProvider.appex    sandboxed replicated File Provider extension;
  │                                  all device I/O goes over XPC to the helper
  └─ Contents/MacOS/
       mtpmount-agent               non-sandboxed helper owning the IOUSBHost
                                    USB session; vends a launchd mach XPC service
```

The app installs the helper as a per-user LaunchAgent and `launchctl
bootstrap`s it; launchd starts it on demand when the extension looks up its
mach service. (We drive launchd directly because BTM won't let `SMAppService`
register a non-sandboxed helper.)

The helper reads MTP folders on demand (`GetObjectHandles` + `GetObjectInfo`,
uncached). Downloads stream the object (`GetObject`/`GetPartialObject`) into a
file descriptor the extension passes over XPC; uploads do the reverse with
`SendObject`. Progress and cancellation travel as `NSProgress`.

Each attached device gets its own File Provider domain, keyed by its USB serial
and named after the device. The helper watches USB hotplug via IOKit, opens
every MTP device, and adds a domain when one appears (or launches the app in the
background with `--sync-domains` if the system won't let the helper do it).

MTP object handles are only valid within one USB session, so a domain's sync
anchor is the device serial, a session id, and a position in a journal of the
device's MTP events (object added/removed), polled once a second. Changes are
reported to Finder item by item; a new session means a full re-enumeration.
Operations on an existing item first check it still matches the version Finder
based the change on.

## Build

Requires the latest Xcode,
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and
an Apple Developer account signed into Xcode. The Xcode project is generated
from `project.yml` and is git-ignored.

```sh
xcodegen generate
xcodebuild -project MtpMount.xcodeproj -scheme MtpMount -configuration Debug \
  -derivedDataPath build build
cp -R build/Build/Products/Debug/MtpMount.app /Applications/
open /Applications/MtpMount.app
```

Then enable the extension as in [Install](#install).

## Packaging & notarization

Both scripts under `scripts/` are configured by environment variables and
auto-detect the Developer ID identity.

- `scripts/bundle-and-sign.sh <app> [--timestamp]` ships the license and
  re-signs everything inside-out with Developer ID and the hardened runtime.
  Config: `SIGN_IDENTITY`, `AGENT_NAME`.
- `scripts/make-dmg.sh <app> [out.dmg] [--notarize]` builds a compressed DMG
  with an `/Applications` drag target, signs it, and optionally notarizes and
  staples it. Config: `SIGN_IDENTITY`, `VOLNAME`, and either `NOTARY_PROFILE`
  (a `notarytool store-credentials` profile) or `NOTARY_KEY` + `NOTARY_KEY_ID`
  + `NOTARY_ISSUER` (an ASC API key).

```sh
xcodebuild -project MtpMount.xcodeproj -scheme MtpMount -configuration Release \
  -derivedDataPath build-release build
APP=build-release/Build/Products/Release/MtpMount.app

scripts/bundle-and-sign.sh "$APP" --timestamp

export NOTARY_KEY=/path/to/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid>
scripts/make-dmg.sh "$APP" dist/MtpMount-0.2.4.dmg --notarize
```

The result passes `spctl -a -t open --context context:primary-signature`.

## Continuous integration

`.github/workflows/ci.yml` runs on an Apple Silicon runner (`macos-26`):

- **build**: on every push/PR, an unsigned compile check (no secrets).
- **release**: on a `v*` tag, builds Release, runs both scripts, and attaches
  the signed, notarized, stapled DMG to the GitHub Release. It runs only when
  the signing secrets are present and imports them into a temporary keychain
  that is deleted afterward.

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | base64 of the Developer ID Application cert + key (`.p12`) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
| `PROVISIONING_PROFILE_APP_BASE64` | base64 of the app's `.provisionprofile` |
| `PROVISIONING_PROFILE_EXT_BASE64` | base64 of the extension's `.provisionprofile` |
| `NOTARY_KEY_P8_BASE64` | base64 of the ASC API key (`.p8`) |
| `NOTARY_KEY_ID` / `NOTARY_ISSUER` | ASC API key id and issuer UUID |

Base64 a file with `base64 -i file -o -`.

## Signing notes

Developer ID manual signing (team `358L7UXVJ4`) against provisioning profiles
created via the App Store Connect API. A File Provider extension **requires**
a provisioning profile (for `com.apple.application-identifier`); bare
Developer ID signing fails. Only the extension is sandboxed; the container app
isn't, so it can install the helper LaunchAgent. Another team must change the
team id and `no.synth.mtpmount*` bundle ids in `project.yml`, the
`*.entitlements` files, and `Shared/*.swift` (`MtpAgentConfig.teamID`).

The helper only accepts XPC connections from the app and extension signed by
this team, and the extension only talks to a helper signed by it, so unsigned
or differently signed local builds can't talk to each other.

## License

GNU General Public License, version 2 or (at your option) any later version.
See [`LICENSE`](LICENSE). The license text ships inside the app
(`Contents/Resources/Licenses`).
