import AppKit

/// Arbiter for the app's process-wide activation policy.
///
/// Runway is a dockless accessory app, but two surfaces need it temporarily promoted to a regular
/// app so their windows reliably come to the front and take keyboard focus — plain
/// `activate(ignoringOtherApps:)` is unreliable while another app is frontmost
/// (sparkle-project/Sparkle#2889): the Settings window and Sparkle's update UI. The policy is one
/// process-wide value, so neither surface may own it alone: each acquires a named hold while its
/// window is up, and the app drops back to `.accessory` only when the last hold releases. Without
/// this, finishing an update check would demote the app while Settings is still open (the Check
/// for Updates button lives inside Settings), and closing Settings would demote a live Sparkle
/// window.
///
/// The injected closures keep the policy transitions unit-testable without trying to automate
/// macOS focus.
@MainActor
final class ActivationPolicyCoordinator {
    /// The surfaces that can hold a foreground promotion. Holds are per-surface (a set, not a
    /// counter): Sparkle re-asserts the front before every UI stage, so one session may acquire
    /// several times against a single release.
    enum Holder: String {
        case settingsWindow
        case updaterUI
    }

    /// The one coordinator the real app uses — holds only coordinate when every surface talks to
    /// the same instance.
    static let shared = ActivationPolicyCoordinator()

    private var holders: Set<Holder> = []
    private let activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let activate: @MainActor (Bool) -> Void

    convenience init(application: NSApplication = .shared) {
        self.init(
            activationPolicy: { application.activationPolicy() },
            setActivationPolicy: { application.setActivationPolicy($0) },
            activate: { application.activate(ignoringOtherApps: $0) }
        )
    }

    init(
        activationPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy,
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool,
        activate: @escaping @MainActor (Bool) -> Void
    ) {
        self.activationPolicy = activationPolicy
        self.setActivationPolicy = setActivationPolicy
        self.activate = activate
    }

    /// Promotes the app to `.regular` (a Dock icon shows while any hold is live) and activates it,
    /// recording the hold. Re-acquiring an already-held surface just re-asserts the front.
    func acquire(_ holder: Holder, reason: String) {
        holders.insert(holder)
        let before = activationPolicy()
        _ = setActivationPolicy(.regular)
        activate(true)
        AppLog.info(
            .lifecycle,
            "foreground acquire (\(holder.rawValue): \(reason), " +
                "policy=\(before.rawValue)->\(activationPolicy().rawValue), holds=\(holders.count))"
        )
    }

    /// Releases the surface's hold. The app returns to the dockless `.accessory` policy only when no
    /// other surface still needs the front; it deliberately never re-activates anything.
    func release(_ holder: Holder) {
        holders.remove(holder)
        guard holders.isEmpty else {
            let remaining = holders.map(\.rawValue).sorted().joined(separator: ", ")
            AppLog.info(.lifecycle, "foreground release (\(holder.rawValue)); still held by \(remaining)")
            return
        }
        _ = setActivationPolicy(.accessory)
        AppLog.info(.lifecycle, "foreground release (\(holder.rawValue)); back to accessory")
    }
}
