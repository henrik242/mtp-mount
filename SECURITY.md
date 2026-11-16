# Security Policy

## Supported versions

Only the latest release gets security fixes. Update to it before reporting.

## Reporting a vulnerability

Report privately through GitHub:
[Report a vulnerability](https://github.com/henrik242/mtp-mount/security/advisories/new)
(Security tab → Advisories → Report a vulnerability). Please don't open a
public issue for a security problem.

Include the MtpMount and macOS versions, the steps to reproduce, and what an
attacker gains. A proof of concept helps.

This is a spare-time project. I aim to acknowledge reports within a week and
will credit you in the advisory unless you'd rather not be named.

## Scope

MtpMount has three parts:

- **The app** (not sandboxed) installs the helper as a per-user LaunchAgent and
  manages the Finder locations.
- **The helper** (`mtpmount-agent`, not sandboxed, runs as you) owns the USB
  device and vends an XPC service. It only accepts connections from code signed
  by the MtpMount team ID with the app's or the extension's bundle identifier.
- **The File Provider extension** (sandboxed) serves files to Finder and talks
  to the helper over XPC.

In scope, for example:

- Another process driving the helper, reading or writing device files, or
  getting around the XPC code-signing check
- A malicious MTP device (or a crafted reply from one) crashing the helper or
  getting code execution through the PTP/MTP parser
- Path or file name handling that lets a device write outside its Finder
  location
- Problems in the release DMG, its signing or notarization, or the Homebrew cask

Out of scope:

- Anyone with physical access to an unlocked phone that is set to "File
  transfer": MTP gives that access by design
- Attacks that need root or an already compromised user account
- Bugs in macOS, Finder or the File Provider framework themselves (report
  those to Apple)
