import AppKit
import XCTest
@testable import Runway

/// The shared activation-policy arbiter for the app's two foreground surfaces (the Settings window
/// and Sparkle's update UI). The policy is process-wide, so a surface releasing its hold must not
/// demote the app while the other surface's window is still up.
@MainActor
final class ActivationPolicyCoordinatorTests: XCTestCase {
    private var policy = NSApplication.ActivationPolicy.accessory
    private var active = false
    private var events: [String] = []

    private func makeCoordinator() -> ActivationPolicyCoordinator {
        ActivationPolicyCoordinator(
            activationPolicy: { self.policy },
            setActivationPolicy: { newPolicy in
                self.events.append("policy:\(newPolicy.rawValue)")
                self.policy = newPolicy
                return true
            },
            activate: { ignoringOtherApps in
                self.events.append("activate:\(ignoringOtherApps)")
                self.active = true
            }
        )
    }

    func testAcquireUsesReliableActivationAfterChangingPolicy() {
        let coordinator = makeCoordinator()

        coordinator.acquire(.updaterUI, reason: "test")

        XCTAssertEqual(policy, .regular)
        XCTAssertTrue(active)
        XCTAssertEqual(events, ["policy:\(NSApplication.ActivationPolicy.regular.rawValue)", "activate:true"])
    }

    func testReleasingLastHoldRestoresAccessoryWithoutReactivating() {
        let coordinator = makeCoordinator()
        coordinator.acquire(.updaterUI, reason: "test")
        events.removeAll()

        coordinator.release(.updaterUI)

        XCTAssertEqual(policy, .accessory)
        XCTAssertEqual(events, ["policy:\(NSApplication.ActivationPolicy.accessory.rawValue)"])
    }

    /// The regression this coordinator exists for: finishing an update check while Settings is still
    /// open (or closing Settings under a live Sparkle window) must not demote the app.
    func testReleasingOneHoldKeepsRegularWhileAnotherSurfaceHolds() {
        let coordinator = makeCoordinator()
        coordinator.acquire(.settingsWindow, reason: "test")
        coordinator.acquire(.updaterUI, reason: "test")

        coordinator.release(.updaterUI)
        XCTAssertEqual(policy, .regular)

        coordinator.release(.settingsWindow)
        XCTAssertEqual(policy, .accessory)
    }

    /// Holds are per-surface, not counted: Sparkle re-asserts the front on every UI stage, so one
    /// release must clear however many acquires that surface issued.
    func testRepeatedAcquiresBySameSurfaceAreOneHold() {
        let coordinator = makeCoordinator()
        coordinator.acquire(.updaterUI, reason: "stage 1")
        coordinator.acquire(.updaterUI, reason: "stage 2")

        coordinator.release(.updaterUI)

        XCTAssertEqual(policy, .accessory)
    }
}

@MainActor
final class UpdaterUserDriverDelegateTests: XCTestCase {
    func testFinishingUpdateSessionRestoresPresentationAndClearsIndicator() {
        let delegate = UpdaterUserDriverDelegate()
        var sessionFinished = false
        var resolved = false
        delegate.onUpdateSessionFinished = { sessionFinished = true }
        delegate.onUpdateResolved = { resolved = true }

        delegate.standardUserDriverWillFinishUpdateSession()

        XCTAssertTrue(sessionFinished)
        XCTAssertTrue(resolved)
    }
}
