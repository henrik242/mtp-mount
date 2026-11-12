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
- **Later:** bundle libmtp into the app for a notarized, self-contained build.

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

## Signing notes

Uses Developer ID manual signing (team `358L7UXVJ4`) against provisioning profiles
created via the App Store Connect API. A File Provider extension **requires**
provisioning profiles (for `com.apple.application-identifier`); bare
Developer ID signing without a profile fails. See the project memory for the full
list of non-obvious requirements.
