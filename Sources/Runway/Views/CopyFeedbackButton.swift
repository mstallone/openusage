import SwiftUI

/// The shared screenshot-copy control used by dashboard headers. The glyph stays compact, but the
/// button owns a larger pointer target; a successful copy swaps it for a green, bouncing checkmark
/// before returning to the copy symbol. Keeping the state and timer here makes every copy action use
/// the same feedback instead of rebuilding the interaction at each call site.
struct CopyFeedbackButton: View {
    let accessibilityLabel: String
    var isRevealed = true
    let action: () -> Bool
    /// Reports when the glyph is actually on screen: revealed by hover, or the post-copy checkmark
    /// lingering after the pointer left. Hosts that collapse the button's reserved space at rest
    /// (the provider header's trailing gutter) key off this instead of the raw hover, so a
    /// lingering checkmark keeps its room until it fades.
    var onPresenceChange: ((Bool) -> Void)?

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private var isPresent: Bool { isRevealed || copied }

    var body: some View {
        Button {
            guard action() else { return }

            withAnimation(Motion.spring) { copied = true }
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .symbolEffect(.bounce, value: copied)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Preserve the header's compact 16pt layout slot while the button's 28pt hit rectangle extends
        // around it. The visible glyph therefore aligns with the old provider-mark position instead of
        // being pushed inward by the larger interaction target.
        .padding(-6)
        .opacity(isPresent ? 1 : 0)
        .allowsHitTesting(isPresent)
        .animation(.easeOut(duration: 0.12), value: isRevealed)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: isPresent) { _, present in
            onPresenceChange?(present)
        }
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }
}
