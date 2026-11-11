# mtp-mount

Mount a Garmin Edge (e.g. Edge 1040) — which exposes its storage over **MTP over
USB** — as a browsable macOS volume, using Apple's **File Provider** API. No kernel
extension, no reboot: the device appears under `~/Library/CloudStorage/` and in
Finder's sidebar, and is usable from the Terminal (`ls`, `cp`, `rsync`).

## Status

- **Phase 0 (done):** signed File Provider app + extension serving a static test
  tree, proving the full macOS pipeline (signing, provisioning, entitlements,
  app group, replicated classification, enablement, enumeration, content fetch).
- **Phase 1 (in progress):** replace the static tree with the real device via a
  `libmtp` background agent + XPC (read-only first: browse + copy `.fit` files off
  the Edge).

## Architecture

```
MtpMount.app                         container app — registers the File Provider domain
  └─ Contents/PlugIns/
       MtpMountFileProvider.appex     sandboxed replicated File Provider extension
garmin-mtp-agent  (Phase 1)          non-sandboxed LaunchAgent owning the libmtp/USB
                                     session, reached by the extension over XPC
```

## Build

Requires Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
xcodegen`), and an Apple Developer account signed into Xcode.

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
