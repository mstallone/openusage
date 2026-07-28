import SwiftUI

/// Shared motion vocabulary so every transition feels consistent and "Apple-native".
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)
    static let modeSwitch = Animation.easeInOut(duration: 0.18)
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
        // Restart from zero so back-to-back triggers each play a full shake.
        phase = 0
        withAnimation(.linear(duration: 0.4)) {
            phase = 1
        }
    }
}
