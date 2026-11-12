# Manual hardware test checklist

Run on a signed build installed in /Applications with the extension enabled,
against a real Garmin Edge (and, where noted, a second MTP device). Watch the
logs with:

```sh
log stream --predicate 'subsystem == "no.synth.mtpmount"' --level debug
```

## Connect / disconnect
- [ ] Plug in with the app closed: the location appears in Finder within a few seconds
- [ ] App window shows "Connected: <device name>"
- [ ] Unplug while idle: app shows "No device connected"; Finder shows the device as offline rather than empty, and nothing is deleted locally
- [ ] Replug: Finder re-enumerates (sync anchor expired) and shows current contents without restarting anything
- [ ] Open Image Capture / Garmin Express first, then plug in: app shows "in use by another app" with the hint; quitting that app and replugging recovers
- [ ] Sleep the Mac with the device attached, wake: first browse works (or recovers on the next try)

## Transfers
- [ ] Copy a `.fit` off the device: bytes identical to a direct libmtp download (`mtp-getfile`)
- [ ] Copy a >100 MB file to and from the device: Finder shows a progress bar
- [ ] Cancel a large copy in Finder: the transfer stops and no partial file is left on the device
- [ ] Unplug during a download: Finder reports an error, the agent reopens after replug
- [ ] Unplug during an upload: no truncated object remains after replug
- [ ] Upload to a full device: Finder reports insufficient space

## Names
- [ ] Unicode and emoji names; names typed in Finder (NFD) round-trip
- [ ] Very long names; names containing `:`
- [ ] Copy a file whose name already exists (different case too): Finder reports a collision instead of creating a duplicate

## Edits
- [ ] Create, rename and delete a folder; delete a non-empty folder
- [ ] Move a file between folders (on a device without MoveObject: a clear "unsupported" error and the session keeps working)
- [ ] Try to edit a file in place (e.g. TextEdit): refused with the "copy it to your Mac" message
- [ ] Rename/delete a file after it was changed on the device in another tool: the change is refused/re-synced, not applied to the wrong object

## Devices
- [ ] A device with an SD card (second storage): a warning is logged and the first storage works
- [ ] Two MTP devices attached: the Garmin one is opened
- [ ] Swap the Edge for a different MTP device: Finder re-enumerates instead of showing the old tree

## Install / uninstall
- [ ] Fresh install from the DMG; run from the DMG first: the app warns to move it to Applications
- [ ] Move the app after installing: reopening it rewrites and reloads the helper
- [ ] Troubleshooting → Uninstall… removes `~/Library/LaunchAgents/no.synth.mtpmount.helper.plist` and the Finder location
- [ ] Relaunching the app does not discard downloaded copies or restart a running transfer
