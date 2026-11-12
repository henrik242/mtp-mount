# Third-party notices

MtpMount is free software, licensed under the GNU General Public License,
version 2 or (at your option) any later version — see `LICENSE`.

Release builds bundle the following libraries in
`MtpMount.app/Contents/Frameworks`, as separate dynamic libraries. Both are
licensed under the GNU Lesser General Public License, version 2.1 or later
(full text in `licenses/LGPL-2.1.txt`). You may replace them with your own
builds of the same libraries.

| Library | Copyright | License | Source |
| --- | --- | --- | --- |
| libmtp | Linus Walleij, Richard A. Low and contributors | LGPL-2.1-or-later | https://github.com/libmtp/libmtp |
| libusb | Johannes Erdfelt, Daniel Drake, Peter Stuge, Nathan Hjelm, Pete Batard and contributors | LGPL-2.1-or-later | https://github.com/libusb/libusb |

The exact versions bundled in a release are listed in
`MtpMount.app/Contents/Resources/Licenses/BUNDLED-VERSIONS.txt`; the source of
those versions is available from the projects above (tags of the same
version), and on request from the MtpMount maintainer.
