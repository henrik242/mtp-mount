// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import IOKit
import IOUSBHost
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "usb")

/// IOReturn values used below (the IOKit macros aren't visible to Swift).
private enum IOReturnCode {
    static let success: Int32 = 0
    static let exclusiveAccess = Int32(bitPattern: 0xE000_02C5)
    static let aborted = Int32(bitPattern: 0xE000_02EB)
}

/// Finds MTP interfaces in the IOKit registry and opens them with IOUSBHost.
final class NativeMtpBus: MtpBus {
    /// Interface services from the last `detect()`, by device location.
    private var services: [UInt64: io_service_t] = [:]

    deinit { services.values.forEach { IOObjectRelease($0) } }

    func detect() throws -> [RawDeviceInfo] {
        services.values.forEach { IOObjectRelease($0) }
        services = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"),
                                           &iterator) == KERN_SUCCESS else {
            throw MtpError(.failed, "Couldn't list USB interfaces.")
        }
        defer { IOObjectRelease(iterator) }
        var found: [RawDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            guard Self.isMTPInterface(service),
                  let location = Self.number(service, "locationID", inParents: true),
                  services[UInt64(location)] == nil else {
                IOObjectRelease(service)
                continue
            }
            let info = RawDeviceInfo(location: UInt64(location),
                                     vendor: UInt16(truncatingIfNeeded: Self.number(service, "idVendor", inParents: true) ?? 0),
                                     product: UInt16(truncatingIfNeeded: Self.number(service, "idProduct", inParents: true) ?? 0))
            services[info.location] = service
            found.append(info)
        }
        return found
    }

    func open(_ info: RawDeviceInfo) throws -> MtpDevice {
        guard let service = services[info.location] else {
            throw MtpError(.noDevice, "The device is no longer attached.")
        }
        return try NativeMtpDevice(transport: USBTransport(service: service))
    }

    // MARK: - Registry

    /// Vendors whose MTP interface is vendor-specific without "MTP" in its name.
    private static let knownMTPVendors: Set<Int> = [0x091E]   // Garmin

    /// PTP/MTP: the Still Image class (PTP, also used by MTP devices and by
    /// phones in PTP mode), or a vendor-specific interface named "MTP"
    /// (Android) or from a known MTP vendor, with bulk in/out + interrupt.
    private static func isMTPInterface(_ service: io_service_t) -> Bool {
        let cls = number(service, "bInterfaceClass") ?? -1
        let sub = number(service, "bInterfaceSubClass") ?? -1
        let proto = number(service, "bInterfaceProtocol") ?? -1
        if cls == 6 && sub == 1 && proto == 1 { return true }
        guard cls == 0xFF, number(service, "bNumEndpoints") == 3 else { return false }
        let name = [string(service, "kUSBString"), string(service, "USB Interface Name")]
            .compactMap { $0 }.joined(separator: " ")
        if name.localizedCaseInsensitiveContains("MTP") { return true }
        return knownMTPVendors.contains(number(service, "idVendor", inParents: true) ?? -1)
    }

    private static func property(_ service: io_service_t, _ key: String, inParents: Bool) -> Any? {
        let options = inParents ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
        return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
    }

    private static func number(_ service: io_service_t, _ key: String, inParents: Bool = false) -> Int? {
        (property(service, key, inParents: inParents) as? NSNumber)?.intValue
    }

    private static func string(_ service: io_service_t, _ key: String) -> String? {
        property(service, key, inParents: false) as? String
    }
}

/// Bulk/interrupt I/O on one PTP/MTP interface via IOUSBHost.
///
/// Synchronous calls are built from IOUSBHost's asynchronous requests: their
/// completions run on this transport's own queue, so waiting for them on the
/// agent's queue can't deadlock. Closing destroys the interface, which aborts
/// every pending request — including the event read — so nothing outlives it.
final class USBTransport: PTPTransport {
    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let interruptIn: IOUSBHostPipe?
    let maxPacketSize: Int
    private let ioQueue = DispatchQueue(label: "no.synth.mtpmount.agent.usb-io")
    /// How long one bulk transfer may take (a big folder can make a device
    /// think for a while before answering).
    private let timeout: TimeInterval = 60

    private let lock = NSLock()
    private var events: [Data] = []
    private var eventsFailed = false
    private var eventFailureReported = false
    private var closed = false

    init(service: io_service_t) throws {
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: ioQueue,
                                               interestHandler: nil)
        } catch {
            let code = Int32(truncatingIfNeeded: (error as NSError).code)
            if code == IOReturnCode.exclusiveAccess {
                throw MtpError(.deviceBusy,
                    "Found a device but couldn't open it. Another app is probably using it (Image Capture, "
                    + "Android File Transfer, OpenMTP or the device maker's sync app) — quit that app and try again.")
            }
            throw MtpError(.noDevice, "Couldn't open the USB interface: \(error.localizedDescription)")
        }

        var bulkInAddress: Int?, bulkOutAddress: Int?, interruptAddress: Int?
        var packet = 512
        let config = interface.configurationDescriptor
        let ifd = interface.interfaceDescriptor
        var current = UnsafeRawPointer(ifd).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(config, ifd, current) {
            let address = Int(endpoint.pointee.bEndpointAddress)
            let type = endpoint.pointee.bmAttributes & 0x03
            let isIn = address & 0x80 != 0
            if type == 2 && isIn {
                bulkInAddress = address
                packet = Int(UInt16(littleEndian: endpoint.pointee.wMaxPacketSize) & 0x7FF)
            } else if type == 2 {
                bulkOutAddress = address
            } else if type == 3 && isIn {
                interruptAddress = address
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let bulkInAddress, let bulkOutAddress else {
            interface.destroy()
            throw MtpError(.noDevice, "The USB interface has no bulk endpoints.")
        }
        let opened = interface   // a local, so the closure below doesn't capture self early
        do {
            bulkIn = try opened.copyPipe(withAddress: bulkInAddress)
            bulkOut = try opened.copyPipe(withAddress: bulkOutAddress)
            interruptIn = try interruptAddress.map { try opened.copyPipe(withAddress: $0) }
        } catch {
            interface.destroy()
            throw MtpError(.noDevice, "Couldn't open the USB endpoints: \(error.localizedDescription)")
        }
        maxPacketSize = max(packet, 64)
        armEventRead()
    }

    deinit { close() }

    // MARK: - PTPTransport

    func write(_ data: Data) throws {
        var buffer: NSMutableData?
        if !data.isEmpty {
            let io = try ioBuffer(data.count)
            data.withUnsafeBytes { io.mutableBytes.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            buffer = io
        }
        let sent = try transfer(bulkOut, buffer)
        if sent != data.count {
            throw MtpError(.disconnected, "Short USB write (\(sent) of \(data.count) bytes).")
        }
    }

    func read(capacity: Int) throws -> Data {
        let io = try ioBuffer(capacity)
        let received = try transfer(bulkIn, io)
        return Data(bytes: io.bytes, count: received)
    }

    func takeEvents() -> [Data]? {
        lock.lock()
        defer { lock.unlock() }
        if eventsFailed {
            // Report the failure once; afterwards there are simply no events.
            if eventFailureReported { return [] }
            eventFailureReported = true
            return nil
        }
        defer { events = [] }
        return events
    }

    func cancelTransaction(_ transactionID: UInt32) throws {
        // Recovering mid-transfer needs a class-specific Cancel request plus
        // pipe resets; reopening the session is simpler and just as effective.
        throw MtpError(.disconnected, "Transfer cancelled; the session will be reopened.")
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { interface.destroy() }
    }

    // MARK: - I/O

    private func ioBuffer(_ size: Int) throws -> NSMutableData {
        do {
            return try interface.ioData(withCapacity: size)
        } catch {
            throw MtpError(.disconnected, "Couldn't allocate a USB buffer: \(error.localizedDescription)")
        }
    }

    /// One synchronous transfer; returns the number of bytes moved.
    private func transfer(_ pipe: IOUSBHostPipe, _ buffer: NSMutableData?) throws -> Int {
        let done = DispatchSemaphore(value: 0)
        var status: IOReturn = IOReturnCode.success
        var moved = 0
        do {
            try pipe.enqueueIORequest(with: buffer, completionTimeout: timeout) { result, bytes in
                status = result
                moved = bytes
                done.signal()
            }
        } catch {
            throw MtpError(.disconnected, "USB request failed: \(error.localizedDescription)")
        }
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            throw MtpError(.disconnected, "The device stopped responding.")
        }
        guard status == IOReturnCode.success else {
            throw MtpError(.disconnected, String(format: "USB transfer failed (IOReturn 0x%08X).", UInt32(bitPattern: status)))
        }
        return moved
    }

    /// Keep one interrupt read outstanding; each completion queues an event
    /// and re-arms it. Runs on `ioQueue`.
    private func armEventRead() {
        guard let pipe = interruptIn else {
            lock.lock(); eventsFailed = true; lock.unlock()
            log.notice("device has no event endpoint; changes made on the device appear after a reconnect")
            return
        }
        let buffer: NSMutableData
        do {
            buffer = try ioBuffer(max(maxPacketSize, 64))
        } catch {
            lock.lock(); eventsFailed = true; lock.unlock()
            return
        }
        do {
            try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, bytes in
                guard let self else { return }
                self.lock.lock()
                if self.closed {
                    self.lock.unlock()
                    return
                }
                if status == IOReturnCode.success {
                    if bytes > 0 { self.events.append(Data(bytes: buffer.bytes, count: bytes)) }
                    self.lock.unlock()
                    self.armEventRead()
                } else {
                    if status != IOReturnCode.aborted { self.eventsFailed = true }
                    self.lock.unlock()
                }
            }
        } catch {
            lock.lock(); eventsFailed = true; lock.unlock()
        }
    }
}
