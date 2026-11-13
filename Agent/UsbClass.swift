// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import IOKit
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "usb")

/// Classifies an attached USB device from its interface descriptors, so a PTP
/// still-image camera can be left to Image Capture *before* we claim it.
///
/// MTP and PTP both ride the USB Still Image class (6/1/1); Android exposes a
/// vendor-specific (0xFF) interface named "MTP" in "File transfer" mode and a
/// plain Still Image interface in "Photos"/PTP mode. So the distinction we need
/// is: does the device advertise MTP anywhere (an "MTP" interface, or a known
/// MTP vendor)? If not, and it only presents Still Image, it's a camera (or a
/// phone in PTP mode) that macOS's Image Capture should own — we can't
/// usefully open it as a file device, and claiming it only keeps Photos and
/// Image Capture from it.
enum UsbClass {
    /// Vendors whose MTP interface is vendor-specific without "MTP" in its name.
    private static let knownMTPVendors: Set<Int> = [0x091E]   // Garmin

    /// The device's product name if it looks like a PTP still-image camera with
    /// no MTP interface (leave it to Image Capture); nil for an MTP device or
    /// when it can't be determined (then we try to open it as before).
    static func ptpCameraName(vendor: UInt16, product: UInt16) -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var sawStillImage = false
        var sawMTP = false
        var name: String?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard number(service, "idVendor", parents: true) == Int(vendor),
                  number(service, "idProduct", parents: true) == Int(product) else { continue }
            name = name ?? string(service, "USB Product Name", parents: true)

            let cls = number(service, "bInterfaceClass")
            let sub = number(service, "bInterfaceSubClass")
            let proto = number(service, "bInterfaceProtocol")
            let ifName = [string(service, "kUSBString"), string(service, "USB Interface Name")]
                .compactMap { $0 }.joined(separator: " ")

            if cls == 6 && sub == 1 && proto == 1 {
                // Still Image (PTP). MTP layered on it names the interface "MTP".
                if ifName.localizedCaseInsensitiveContains("MTP") { sawMTP = true } else { sawStillImage = true }
            } else if cls == 0xFF {
                if ifName.localizedCaseInsensitiveContains("MTP") || knownMTPVendors.contains(Int(vendor)) {
                    sawMTP = true
                }
            }
        }

        guard sawStillImage, !sawMTP else { return nil }
        return name ?? "Camera"
    }

    private static func property(_ service: io_service_t, _ key: String, parents: Bool) -> Any? {
        let options = parents ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
        return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
    }

    private static func number(_ service: io_service_t, _ key: String, parents: Bool = false) -> Int? {
        (property(service, key, parents: parents) as? NSNumber)?.intValue
    }

    private static func string(_ service: io_service_t, _ key: String, parents: Bool = false) -> String? {
        property(service, key, parents: parents) as? String
    }
}
