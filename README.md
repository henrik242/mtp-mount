# mtp-mount

Mount a Garmin Edge (e.g. Edge 1040) — which exposes its storage over **MTP over
USB** — as a browsable macOS volume, using Apple's **File Provider** API. No kernel
extension, no reboot: the device appears under `~/Library/CloudStorage/` and in
Finder's sidebar, and is usable from the Terminal (`ls`, `cp`, `rsync`).

## Status

- **Phase 0 (done):** signed File Provider app + extension serving a static test
  tree, proving the full macOS pipeline (signing, provisioning, entitlements,
  app group, replicated classification, enablement, enumeration, content fetch).
- **Phase 1 (done):** the extension serves the **real device** over a `libmtp`
  background agent + XPC. Browse the Edge in Finder and the Terminal and copy
  files off it (`ls`, `cp`, `rsync`). Verified: copied `.fit` bytes are identical
  to a direct libmtp download.
- **Phase 2 (done):** read **/write**. Upload files (e.g. courses/workouts into
  `Garmin/NewFiles`), create folders, rename, move, and delete — all from Finder
  or the Terminal. In-place content edits aren't offered (MTP has no partial
  write; an edit would change the object id).
- **Packaging (done):** libmtp + libusb are bundled into the app and the whole
  thing is Developer ID signed, hardened, notarized and stapled — no Homebrew
  dependency at runtime. See [Packaging & notarization](#packaging--notarization).

## Architecture

```
MtpMount.app                        container app (NOT sandboxed) — registers the
  │                                 File Provider domain and installs the helper
  ├─ Contents/PlugIns/
  │    MtpMountFileProvider.appex    sandboxed replicated File Provider extension;
  │                                  all device I/O goes over XPC to the helper
  └─ Contents/MacOS/
       garmin-mtp-agent             non-sandboxed helper owning the single libmtp
                                    USB session; vends a launchd mach XPC service
```

The app installs the helper as a per-user LaunchAgent
(`~/Library/LaunchAgents/no.synth.mtpmount.helper.plist`) and `launchctl
bootstrap`s it; launchd then starts it on demand when the extension looks up its
mach service. (We drive launchd directly instead of `SMAppService` because BTM
refuses to let an app register a non-sandboxed helper.)

The helper reads MTP folders on demand (`LIBMTP_Get_Files_And_Folders`, uncached)
for enumeration, and for a file download streams
`LIBMTP_Get_File_To_File_Descriptor` into a file descriptor the sandboxed
extension passes over XPC.

## Build

Requires Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
xcodegen`), **libmtp** (`brew install libmtp`), and an Apple Developer account
signed into Xcode. The helper currently links Homebrew's libmtp at
`/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib`.

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
Extensions → turn on the MtpMount / "GarminEdge" File Provider. (Apps installed
outside the App Store register their providers disabled, pending approval.)

The volume then appears at `~/Library/CloudStorage/MtpMount-GarminEdge`.

## Packaging & notarization

Two scripts under `scripts/` do the packaging. Both are configured by environment
variables with sensible defaults (they auto-detect the Developer ID identity and
find libmtp via Homebrew), so they carry no machine-specific paths.

`scripts/bundle-and-sign.sh <app> [--timestamp]` makes a built app self-contained:
it copies `libmtp.9.dylib` and `libusb-1.0.0.dylib` into `Contents/Frameworks`,
rewrites their link paths to `@rpath`, and re-signs everything inside-out with
Developer ID and the hardened runtime. After this the app needs no Homebrew at
runtime. Config: `SIGN_IDENTITY`, `LIBMTP_DYLIB`, `AGENT_NAME`.

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
scripts/make-dmg.sh "$APP" dist/MtpMount-0.1.0.dmg --notarize
```

The result passes `spctl -a -t open --context context:primary-signature` and is
ready to hand out.

## Continuous integration

`.github/workflows/ci.yml`:

- **build** — on every push/PR, installs XcodeGen + libmtp and does an *unsigned*
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

Base64 a file with `base64 -i file -o -` (or `base64 < file`). GitHub's runners
are Apple Silicon, so Homebrew lives at `/opt/homebrew` as the project expects.

## Signing notes

Uses Developer ID manual signing (team `358L7UXVJ4`) against provisioning profiles
created via the App Store Connect API. A File Provider extension **requires**
provisioning profiles (for `com.apple.application-identifier`); bare
Developer ID signing without a profile fails. The container app is **not**
sandboxed (so it can install the helper LaunchAgent directly); only the extension
is sandboxed, as the system requires. A different developer/team must change the
team id and `no.synth.mtpmount*` bundle ids in `project.yml`, the `*.entitlements`
files, and `Shared/*.swift`. See the project memory for the full list of
non-obvious requirements.

## Signing notes

Uses Developer ID manual signing (team `358L7UXVJ4`) against provisioning profiles
created via the App Store Connect API. A File Provider extension **requires**
provisioning profiles (for `com.apple.application-identifier`); bare
Developer ID signing without a profile fails. The container app is **not**
sandboxed (so it can install the helper LaunchAgent directly); only the extension
is sandboxed, as the system requires. See the project memory for the full list of
non-obvious requirements.
