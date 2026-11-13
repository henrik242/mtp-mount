# Manual hardware test checklist

Run on a signed build installed in /Applications with the extension enabled,
against real MTP devices — at least an Android phone and one non-phone device
(GPS, camera, player) — and, where noted, two at once. Watch the
logs with:

```sh
log stream --predicate 'subsystem == "no.synth.mtpmount"' --level debug
```

## Connect / disconnect
- [ ] Plug in with the app closed: the location appears in Finder within a few seconds
- [ ] App window shows "Connected: <device name>"
- [ ] Unplug while idle: app shows "No device connected"; Finder shows the device as offline rather than empty, and nothing is deleted locally
- [ ] Replug: Finder re-enumerates (sync anchor expired) and shows current contents without restarting anything
- [ ] Phone locked / USB mode "Charging only": app explains to unlock and choose "File transfer"; switching mode connects without replugging
- [ ] Open Image Capture / Android File Transfer / a vendor sync app first, then plug in: app shows "in use by another app" with the hint; quitting that app and replugging recovers
- [ ] Sleep the Mac with the device attached, wake: first browse works (or recovers on the next try)

## Changes made on the device
- [ ] Phone connected and a folder open in Finder: take a photo → it appears in `DCIM/Camera` within a few seconds, without replugging
- [ ] Delete a file on the phone → it disappears from Finder
- [ ] Insert/remove an SD card (if the device has one) → Finder re-enumerates
- [ ] Devices that send no MTP events: still work; changes show after a reconnect (log says "device events unavailable")

## Transfers
- [ ] Copy a file off the device: the copy is byte-for-byte intact (same size, opens/plays, and a second copy of the same file matches `shasum`)
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
- [ ] Two MTP devices attached (e.g. phone + GPS): each appears as its own Finder location, named after the device, and both work at the same time
- [ ] Unplug one of them: its location shows as unavailable, the other keeps working; replug brings it back with current contents
- [ ] "Forget" on an unplugged device removes its location; it comes back when the device is attached again
- [ ] With the app closed, attach a never-seen device: its location appears (added by the helper, or by the app launched in the background)

- [ ] An MTP camera (or a phone switched to PTP/"Transfer photos" mode with only DCIM): not opened, listed as "Left to Image Capture", and Image Capture/Photos can import from it
- [ ] Switch that phone back to "File transfer": it's opened and gets its location

## Install / uninstall
- [ ] Upgrading from a build with the old "Garmin Edge" / "MTP Device" location: it is removed and per-device locations appear
- [ ] Fresh install from the DMG; run from the DMG first: the app warns to move it to Applications
- [ ] Move the app after installing: reopening it rewrites and reloads the helper
- [ ] Troubleshooting → Uninstall… removes `~/Library/LaunchAgents/no.synth.mtpmount.helper.plist` and the Finder location
- [ ] Relaunching the app does not discard downloaded copies or restart a running transfer
