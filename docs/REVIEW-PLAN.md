# Review fix plan

Findings from the multi-expert review (MTP, USB, UX, macOS, over-engineering,
clean code, testing), turned into a checklist. Each fix lands as its own commit
on the working branch; boxes are ticked as they land. Items marked *deferred*
or *won't fix* carry the reason inline.

Platform decision: Apple Silicon only, latest macOS/Xcode (no Intel support).

## Build & CI
- [x] CI builds every branch push (so each fix is compile-checked)
- [x] Latest runner/Xcode (`macos-26`), deployment target matches the bundled Homebrew dylibs, arm64 only
- [x] `contents: write` scoped to the release job only

## Critical
- [x] 1. XPC: agent only accepts connections from our team-signed extension/app; client pins the agent's signature
- [x] 2. Device identity: agent records the device serial; sync anchor = serial + connection epoch; destructive ops verify `baseVersion` against the device first, so a stale object handle can't hit an unrelated file
- [x] 3. Change tracking: real sync anchor; `enumerateChanges` returns `.syncAnchorExpired` when the device/epoch changes; USB hotplug (IOKit) in the agent bumps the epoch and signals the working set
- [x] 4. libmtp error stack is read after every call and cleared (no silent "empty folder" / "no such item" on I/O errors, no unbounded growth)

## High
- [x] 5. App launch no longer wipes the domain (`removeAllDomains`) or boots out a running agent; explicit "Reset" instead
- [x] 6. Agent drops the USB session only on transport errors, not on logical refusals
- [x] 7. Structured errors over XPC, mapped to `NSFileProviderError` (`serverUnreachable`, `noSuchItem`, `filenameCollision`, `insufficientQuota`, `directoryNotEmpty`, …)
- [x] 8. `modifyItem`: content edits / unknown parents (Trash) are rejected instead of silently "succeeding"; `baseVersion` checked
- [x] 9. `createItem` returns the device's real metadata; honours `.mayAlreadyExist`; refuses duplicate names
- [x] 10. dylib/OS mismatch: deployment target = runner OS; bundle script verifies arm64 + `minos`
- [x] 11. "Device in use by another app" detected and reported clearly (agent, Finder error, app UI, README)

## Medium
- [x] `createFolder` passes a `strdup` copy to libmtp (no UB)
- [x] Byte progress + cancellation for uploads/downloads (libmtp callbacks ↔ `Progress` over XPC); partial uploads are cleaned up
- [x] Folder delete honours `.recursive`; non-recursive delete of a non-empty folder → `.directoryNotEmpty`
- [x] Move checks the MoveObject capability and returns "unsupported" instead of resetting the session
- [x] Defensive parent filtering when listing (devices that ignore the parent filter at root)
- [x] Detection of an absent device is rate-limited (no USB probe storm)
- [x] `launchctl` runs off the main actor and reads the pipe before waiting
- [x] AgentClient: interruption keeps the connection; invalidation only clears the matching connection; temp file removed on XPC error; temp files go in the domain's temporary directory
- [x] LaunchAgent plist is rewritten + re-bootstrapped when the app has moved; warn when not run from /Applications
- [x] `disable-library-validation` only in Debug (release agent signed without it)
- [x] Scripts: `.appex` lookup can't silently exit under `pipefail`; libusb resolved robustly; `make-dmg.sh` parses flags properly, uses `ditto`, fails on Gatekeeper rejection when notarizing
- [x] Provisioning profiles installed where current Xcode looks for them
- [ ] *deferred* — multiple storages (SD card) shown as top-level folders: needs an identifier scheme change and hardware to test; a warning is logged when a device has >1 storage
- [ ] *deferred* — copy+delete fallback for devices without MoveObject (File Provider requires the identifier to stay stable across `modifyItem`, which a re-upload can't do)
- [ ] *won't fix* — `SMAppService` instead of a hand-written LaunchAgent: the README records that BTM refuses the non-sandboxed helper; relocation is handled instead

## Low / cleanup
- [x] Root item is not deletable/renamable/movable
- [x] Packages/symlinks → "unsupported" instead of `.noSuchItem`
- [x] Dead code removed (`download(id:to:)`, `cloudStoragePath`, duplicate app-group + `rootParent` constants)
- [x] Stale comments ("read-only phase", app-group drop, `status` doc) fixed
- [x] `project.yml` duplicates removed; stale SMAppService comment corrected
- [x] Agent boilerplate collapsed into one helper
- [x] Hard-coded "Garmin Edge" root name uses `FP.domainDisplayName`; team ID / subsystem in one place
- [x] Force-unwraps of `error!` removed
- [ ] *deferred* — pin GitHub Actions by SHA
- [ ] *deferred* — localization (`.xcstrings`)
- [ ] *won't fix (needs hardware)* — libmtp timestamp timezone interpretation

## UX
- [x] App shows device state (connected / no device / in use by another app / agent not running) with a next step
- [x] Extension-disabled detection with a button to open Login Items & Extensions settings
- [x] Debug buttons moved under "Troubleshooting"; "Show in Finder" opens the device folder
- [x] Uninstall action (boots out agent, removes plist + domain)
- [x] One product name everywhere; SF Symbols with accessibility labels instead of "✓"
- [x] README: end-user quick start, troubleshooting (incl. Image Capture), uninstall; duplicate section removed

## Testing
- [x] Unit-test target (pure logic: ID mapping, items/versions, error mapping, sync anchors, error classification)
- [x] Agent depends on an `MtpDevice` protocol; in-memory fake device tests for session recovery / error-drop policy / recursive delete
- [x] CI runs the tests and `shellcheck`
- [x] Manual hardware checklist (`docs/HARDWARE-TESTS.md`)
