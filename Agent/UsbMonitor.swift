import Foundation
import IOKit
import os

private let log = Logger(subsystem: MtpAgentConfig.logSubsystem, category: "usb")

/// Watches for USB devices arriving or leaving (IOKit matching notifications)
/// and calls `onChange`, debounced, so the agent can open a newly attached
/// device or notice that its device is gone without waiting for a failing
/// request.
final class UsbMonitor {
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?

    init(queue: DispatchQueue = DispatchQueue(label: "no.synth.mtpmount.agent.usb"),
         debounce: TimeInterval = 1.0,
         onChange: @escaping () -> Void) {
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("IOUSBHostDevice"),
                { context, iterator in
                    guard let context else { return }
                    let monitor = Unmanaged<UsbMonitor>.fromOpaque(context).takeUnretainedValue()
                    monitor.drain(iterator)
                    monitor.scheduleChange()
                },
                context, &iterator)
            guard kr == KERN_SUCCESS else {
                log.error("IOServiceAddMatchingNotification(\(type, privacy: .public)) failed: \(kr)")
                continue
            }
            drain(iterator)   // arms the notification; existing devices aren't news
            iterators.append(iterator)
        }
        log.info("watching USB hotplug")
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
