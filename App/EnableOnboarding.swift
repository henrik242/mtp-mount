// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The "allow MtpMount in Finder" onboarding as plain state: which locations
/// count as needing enabling, when to bring the window forward, and which
/// devices to open in Finder once the user has enabled them.
struct EnableOnboarding {
    struct Location: Equatable {
        let key: String
        let connected: Bool
        let userEnabled: Bool
    }

    struct Update: Equatable {
        var needsEnabling: Set<String> = []
        /// Bring the window forward: true once per run, on the first location
        /// that needs enabling.
        var prompt = false
        /// Keys that were shown as needing enabling and now are enabled.
        var reveal: [String] = []
    }

    /// A freshly (re-)added domain can report itself not-enabled for a second
    /// before the system settles, so only act once it has stayed that way this
    /// long; otherwise a replug would flash the notice.
    let grace: TimeInterval
    private var notEnabledSince: [String: Date] = [:]
    private var prompted = false
    private var awaiting: Set<String> = []

    init(grace: TimeInterval = 6) { self.grace = grace }

    mutating func update(_ locations: [Location], now: Date) -> Update {
        var result = Update()
        var since: [String: Date] = [:]
        for location in locations where !location.userEnabled {
            let start = notEnabledSince[location.key] ?? now
            since[location.key] = start
            if now.timeIntervalSince(start) >= grace { result.needsEnabling.insert(location.key) }
        }
        notEnabledSince = since

        if !prompted, !result.needsEnabling.isEmpty {
            prompted = true
            result.prompt = true
        }

        // A disconnected row (helper down) stays awaiting until it's back.
        for location in locations where awaiting.contains(location.key)
            && location.userEnabled && location.connected {
            result.reveal.append(location.key)
            awaiting.remove(location.key)
        }
        awaiting = awaiting.intersection(locations.map(\.key)).union(result.needsEnabling)
        return result
    }
}
