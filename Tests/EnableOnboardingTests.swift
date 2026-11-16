// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

final class EnableOnboardingTests: XCTestCase {
    private typealias Location = EnableOnboarding.Location
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private var onboarding = EnableOnboarding(grace: 6)

    private func off(_ key: String, connected: Bool = true) -> Location {
        Location(key: key, connected: connected, userEnabled: false)
    }

    private func on(_ key: String, connected: Bool = true) -> Location {
        Location(key: key, connected: connected, userEnabled: true)
    }

    private func update(_ locations: [Location], at seconds: TimeInterval) -> EnableOnboarding.Update {
        onboarding.update(locations, now: t0.addingTimeInterval(seconds))
    }

    func testNotEnabledWithinGraceIsNotFlagged() {
        XCTAssertEqual(update([off("a")], at: 0), .init())
        XCTAssertEqual(update([off("a")], at: 5), .init())
    }

    func testPastGraceFlagsAndPromptsOnce() {
        _ = update([off("a")], at: 0)
        XCTAssertEqual(update([off("a")], at: 6), .init(needsEnabling: ["a"], prompt: true))
        XCTAssertEqual(update([off("a")], at: 7), .init(needsEnabling: ["a"]))
    }

    func testGraceRestartsAfterLocationGoes() {
        _ = update([off("a")], at: 0)
        _ = update([], at: 3)
        _ = update([off("a")], at: 4)
        XCTAssertEqual(update([off("a")], at: 9).needsEnabling, [])
        XCTAssertEqual(update([off("a")], at: 10).needsEnabling, ["a"])
    }

    func testSecondDeviceDoesNotPromptAgain() {
        _ = update([off("a")], at: 0)
        XCTAssertTrue(update([off("a")], at: 6).prompt)
        _ = update([off("a"), off("b")], at: 7)
        let later = update([off("a"), off("b")], at: 13)
        XCTAssertEqual(later.needsEnabling, ["a", "b"])
        XCTAssertFalse(later.prompt)
    }

    func testAlreadyEnabledNeverPromptsOrReveals() {
        XCTAssertEqual(update([on("a")], at: 0), .init())
        XCTAssertEqual(update([on("a")], at: 10), .init())
    }

    func testRevealsOnceWhenEnabled() {
        _ = update([off("a")], at: 0)
        _ = update([off("a")], at: 6)
        XCTAssertEqual(update([on("a")], at: 8).reveal, ["a"])
        XCTAssertEqual(update([on("a")], at: 9).reveal, [])
    }

    func testEnabledDuringGraceDoesNotReveal() {
        _ = update([off("a")], at: 0)
        XCTAssertEqual(update([on("a")], at: 3), .init())
    }

    func testDisconnectedRevealsAfterReconnect() {
        _ = update([off("a")], at: 0)
        _ = update([off("a")], at: 6)
        XCTAssertEqual(update([on("a", connected: false)], at: 8).reveal, [])
        XCTAssertEqual(update([on("a")], at: 9).reveal, ["a"])
    }

    func testUnpluggedWhileAwaitingIsForgotten() {
        _ = update([off("a")], at: 0)
        _ = update([off("a")], at: 6)
        _ = update([], at: 7)
        XCTAssertEqual(update([on("a")], at: 8).reveal, [])
    }

    func testEnablingRevealsEveryAwaitingDevice() {
        _ = update([off("a"), off("b")], at: 0)
        _ = update([off("a"), off("b")], at: 6)
        XCTAssertEqual(Set(update([on("a"), on("b")], at: 8).reveal), ["a", "b"])
    }

    func testDisableAgainRevealsAgainWithoutPrompt() {
        _ = update([off("a")], at: 0)
        _ = update([off("a")], at: 6)
        _ = update([on("a")], at: 8)
        _ = update([off("a")], at: 10)
        XCTAssertEqual(update([on("a")], at: 12).reveal, [], "re-disabled but still within grace")
        _ = update([off("a")], at: 20)
        let flagged = update([off("a")], at: 26)
        XCTAssertEqual(flagged.needsEnabling, ["a"])
        XCTAssertFalse(flagged.prompt)
        XCTAssertEqual(update([on("a")], at: 27).reveal, ["a"])
    }
}
