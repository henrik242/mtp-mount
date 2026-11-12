import Foundation
import FileProvider

/// File Provider domains: one per MTP device, identified by its `DeviceKey`
/// and named after the device (the name shown in Finder's sidebar and used
/// for its ~/Library/CloudStorage folder).
enum FP {
    /// Domains created by earlier versions (one shared location), removed on launch.
    static let legacyDomainIdentifiers: Set<String> = ["GarminEdge", "MtpDevice"]

    static func domain(forDevice key: String, name: String) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: key), displayName: name)
    }

    /// The device a domain belongs to, or nil for a domain that isn't per-device.
    static func deviceKey(of domain: NSFileProviderDomain) -> String? {
        DeviceKey.isDeviceKey(domain.identifier.rawValue) ? domain.identifier.rawValue : nil
    }

    /// A manager for an existing domain (the display name doesn't matter for lookup).
    static func manager(forDevice key: String) -> NSFileProviderManager? {
        NSFileProviderManager(for: domain(forDevice: key, name: key))
    }
}
