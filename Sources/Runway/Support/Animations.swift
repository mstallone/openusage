import AppKit
import SwiftUI

/// Shared motion vocabulary so every transition feels consistent and "Apple-native".
///
/// Honors the system Reduce Motion accessibility setting: when it's on, the bouncy spring and the
/// mode-switch ease both collapse to one short, travel-free ease so state changes read as quick
/// fades rather than movement. Computed per animation start (never per frame), so flipping the
/// setting applies to the next interaction with no restart. Views that add their own translation
/// (the screen-switch entrance slide) separately zero their travel via
/// `\.accessibilityReduceMotion`.
enum Motion {
    static var spring: Animation {
        reduceMotion ? reducedMotionFallback : .spring(response: 0.42, dampingFraction: 0.80)
    }

    static var modeSwitch: Animation {
        reduceMotion ? reducedMotionFallback : .easeInOut(duration: 0.18)
    }

    /// Reduced-motion-aware stand-in for ad-hoc `.snappy` animations in views.
    static var snappy: Animation {
        reduceMotion ? reducedMotionFallback : .snappy(duration: 0.25)
    }

    /// For effects that can't be expressed as a shorter curve (the deny shake's travel, decorative
    /// pulses): check this and skip the motion entirely.
    static var reduceMotionEnabled: Bool { reduceMotion }

    /// Fast enough that height/size changes read as an immediate replacement (no visible travel),
    /// while still letting SwiftUI coalesce the frame change cleanly.
    private static var reducedMotionFallback: Animation { .linear(duration: 0.05) }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension AnyTransition {
    /// A scale+fade entrance that collapses to an instant swap under Reduce Motion — scaling is
    /// exactly the kind of zoom the setting asks to avoid, and opacity transitions composite
    /// translucent material cards into transparency layers where they flash opaque (see
    /// `DashboardView.modeBody`), so the reduced form is `.identity`, not a fade.
    static func scaleOrInstant(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition {
        Motion.reduceMotionEnabled
            ? .identity
            : .scale(scale: scale, anchor: anchor).combined(with: .opacity)
    }
}

extension View {
    /// The macOS "denied" idiom: a brief horizontal shake, like the login window on a wrong
    /// password. Increment `trigger` to play one shake; repeats re-shake so a second blocked
    /// click still gets feedback while the label is already showing.
    ///
    /// `shakeOnAppear` is for labels *inserted by* the denial itself (their `onChange` never sees
    /// the first bump). Leave it off for persistent labels that merely mount on mode switches —
    /// otherwise they replay an old shake every time they appear.
    func denyShake(trigger: Int, shakeOnAppear: Bool = false) -> some View {
        modifier(DenyShakeModifier(trigger: trigger, shakeOnAppear: shakeOnAppear))
    }
}

/// Horizontal sine shake driven by an animatable phase (0→1 plays `shakes` full oscillations).
private struct DenyShakeEffect: GeometryEffect {
    var phase: CGFloat
    var travel: CGFloat = 5
    var shakes: CGFloat = 3

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(phase * .pi * shakes * 2),
            y: 0
        ))
    }
}

private struct DenyShakeModifier: ViewModifier {
    let trigger: Int
    let shakeOnAppear: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(DenyShakeEffect(phase: phase))
            .onChange(of: trigger) { shake() }
            .onAppear {
                if shakeOnAppear, trigger > 0 { shake() }
            }
    }

    private func shake() {
        // Reduce Motion: the shake IS travel — there is no shorter-curve version of it. The denial
        // feedback still reaches the user through the notice label the shake accompanies.
        guard !Motion.reduceMotionEnabled else { return }
        // Restart from zero so back-to-back triggers each play a full shake.
        phase = 0
        withAnimation(.linear(duration: 0.4)) {
            phase = 1
        }
    }
}
