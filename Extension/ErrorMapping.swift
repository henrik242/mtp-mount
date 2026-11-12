// SPDX-License-Identifier: GPL-2.0-or-later
import FileProvider

/// Build a File Provider error, optionally with a user-facing message and the
/// underlying cause.
func fpError(_ code: NSFileProviderError.Code, _ message: String? = nil,
             underlying: Error? = nil) -> NSError {
    var info: [String: Any] = [:]
    if let message { info[NSLocalizedDescriptionKey] = message }
    if let underlying { info[NSUnderlyingErrorKey] = underlying }
    return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: info)
}

/// A Cocoa error (the convention for "unsupported" / permission / cancel).
func cocoaError(_ code: Int, _ message: String, underlying: Error? = nil) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: message]
    if let underlying { info[NSUnderlyingErrorKey] = underlying }
    return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: info)
}

/// Maps agent and XPC failures to the errors the File Provider system acts on:
/// `.serverUnreachable` makes it back off and retry later (device unplugged or
/// busy), `.noSuchItem` removes the item, collisions/quota surface properly in
/// Finder, and everything else becomes `.cannotSynchronize` with the message.
enum FileProviderErrors {
    static func map(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSFileProviderErrorDomain { return ns }
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSXPCConnectionInterrupted || ns.code == NSXPCConnectionInvalid {
            return fpError(.serverUnreachable, "The MtpMount helper isn't running. Open MtpMount to reinstall it.",
                           underlying: ns)
        }
        guard let failure = ns.mtpFailure else { return ns }
        let message = ns.localizedDescription
        switch failure {
        case .noDevice, .deviceBusy, .disconnected, .notFileDevice:
            return fpError(.serverUnreachable, message, underlying: ns)
        case .noSuchObject:
            return fpError(.noSuchItem, message, underlying: ns)
        case .storageFull:
            return fpError(.insufficientQuota, message, underlying: ns)
        case .directoryNotEmpty:
            return fpError(.directoryNotEmpty, message, underlying: ns)
        case .nameCollision:
            return fpError(.filenameCollision, message, underlying: ns)
        case .unsupported:
            return cocoaError(NSFeatureUnsupportedError, message, underlying: ns)
        case .accessDenied:
            return cocoaError(NSFileWriteNoPermissionError, message, underlying: ns)
        case .cancelled:
            return cocoaError(NSUserCancelledError, message, underlying: ns)
        case .failed:
            return fpError(.cannotSynchronize, message, underlying: ns)
        }
    }
}
