import SwiftUI

/// Lets a provider card's expand/collapse caret co-animate the panel height in the SAME transaction
/// as the row change. Without this the height retarget waits for the content measurement (~2 frames),
/// so two springs run on offset clocks — SwiftUI then samples animations off-vsync and the footer,
/// which rides the height spring, visibly jitters behind the unfolding rows. `DashboardView` installs
/// the closure; the caret calls it inside its `withAnimation` just before toggling, passing the
/// provider and whether it is expanding.
private struct ExpansionCoAnimationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (_ providerID: String, _ expanding: Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var coAnimateExpansion: (@MainActor (String, Bool) -> Void)? {
        get { self[ExpansionCoAnimationKey.self] }
        set { self[ExpansionCoAnimationKey.self] = newValue }
    }
}
