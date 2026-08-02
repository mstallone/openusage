import SwiftUI

/// The Memory Explorer window's SwiftUI root, in an inverted (Arc-style) hierarchy: the whole
/// window is one behind-window vibrancy backdrop — the navigation layer, with the sidebar sitting
/// directly on it, no panel chrome — and the editor floats on top of it as an opaque rounded card,
/// the content layer. This keeps the app's surface rules intact: glass and vibrancy stay in the
/// chrome, the memory text sits on an opaque card that never fights the desktop showing through.
/// The window controller hosts this with a `MemoryStore` in the environment; the first appearance
/// kicks off the initial scan, and the sidebar footer's Refresh (⌘R) re-runs it on demand.
struct MemoryRootView: View {
    @Environment(MemoryStore.self) private var store

    /// A Refresh that arrived while the editor held unsaved changes — a re-scan can drop the loaded
    /// document (or empty the whole inventory, unmounting the editor), so it asks first.
    @State private var isPromptingDirtyRefresh = false
    @State private var refreshError: String?

    private static let sidebarWidth: CGFloat = 272
    /// The floating card's margin to the true window edges (the titlebar is transparent, so "top"
    /// is the real top of the window).
    private static let cardInset: CGFloat = 10
    /// Clearance under the floating traffic lights for the sidebar's first rows.
    private static let titlebarClearance: CGFloat = 34

    var body: some View {
        ZStack {
            MemoryWindowBackdrop()
                .ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar
                contentCard
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
        }
        .task {
            // The controller builds the store lazily on open; the first mount owns the initial scan.
            if store.sources.isEmpty && !store.isLoading {
                await store.reload()
            }
        }
        .confirmationDialog("Save Changes?", isPresented: $isPromptingDirtyRefresh) {
            Button("Save") {
                Task {
                    do {
                        try await MemoryEditorState.shared.saveDirtyDocument?()
                        await store.reload()
                    } catch MemoryEditorError.conflictDetected {
                        // The editor's Reload / Overwrite banner is up; refresh once it's answered.
                    } catch {
                        refreshError = error.localizedDescription
                    }
                }
            }
            Button("Discard Changes", role: .destructive) {
                Task {
                    await store.reload()
                    // The re-scan alone leaves a still-existing selection's dirty buffer mounted;
                    // discarding means the disk copy replaces it.
                    MemoryEditorState.shared.discardBufferAndReload?()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This memory has unsaved changes. Refreshing re-scans the files on disk.")
        }
        .alert("Something Went Wrong", isPresented: presentingRefreshError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refreshError ?? "")
        }
    }

    private var presentingRefreshError: Binding<Bool> {
        Binding(
            get: { refreshError != nil },
            set: { if !$0 { refreshError = nil } }
        )
    }

    // MARK: - Columns

    /// The sidebar rows painted straight onto the window backdrop, with the traffic lights floating
    /// above the first rows and the Refresh control pinned at the bottom like a status strip.
    ///
    /// Each edge fades scrolled rows out instead of letting them draw hard-edged behind the chrome,
    /// via a different mechanism per edge:
    /// - **Bottom**: the footer is a safe-area bar (`pinnedFooter`), which on macOS 26 feeds the
    ///   native soft scroll-edge effect (`softBottomScrollEdge`).
    /// - **Top**: there is no bar content to anchor that effect — the traffic lights are AppKit
    ///   chrome floating above the SwiftUI tree, and the system never renders a scroll-edge effect
    ///   for an empty/clear safe-area bar (Apple Forums thread 787796). So the clearance is plain
    ///   safe-area padding, and `SidebarTitlebarFade` paints the fade instead.
    private var sidebar: some View {
        MemorySidebarView()
            .softBottomScrollEdge()
            .safeAreaPadding(.top, Self.titlebarClearance)
            // Keeps the scrollbar out of the frost: indicators already start below the safe-area
            // clearance, so pushing them down by the fade's dissolve tail as well means the knob
            // only ever runs through crisp rows.
            .contentMargins(.top, SidebarTitlebarFade.dissolve, for: .scrollIndicators)
            .pinnedFooter(spacing: 0) { sidebarFooter }
            .overlay(alignment: .top) {
                SidebarTitlebarFade(clearance: Self.titlebarClearance)
            }
            .frame(width: Self.sidebarWidth)
    }

    private var sidebarFooter: some View {
        HStack {
            Button {
                if MemoryEditorState.shared.isDirty {
                    isPromptingDirtyRefresh = true
                } else {
                    Task { await store.reload() }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .interactiveGlass(in: Circle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isLoading)
            .accessibilityLabel("Refresh")

            Spacer()

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The scan states first (initial spinner, nothing found), otherwise the editor — which stays
    /// mounted across selection changes so a dirty buffer can prompt before switching. Whatever the
    /// state, it rides on the same floating opaque card; state swaps crossfade (the ZStack keeps
    /// both branches mounted for the transition) instead of popping.
    private var contentCard: some View {
        ZStack {
            detail
        }
        .animation(Motion.modeSwitch, value: detailState)
        // The card owns the full column whatever state is showing — without this, a
        // content-sized state (the editor's placeholders) would shrink the whole card.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.traySurface)
        .clipShape(Theme.cardShape)
        .overlay { Theme.cardShape.strokeBorder(.separator, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
        .padding([.top, .bottom, .trailing], Self.cardInset)
        .padding(.leading, 6)
    }

    private enum DetailState: Equatable {
        case scanning, nothingFound, editor
    }

    private var detailState: DetailState {
        if store.isLoading && store.sources.isEmpty { return .scanning }
        if store.sources.isEmpty { return .nothingFound }
        return .editor
    }

    @ViewBuilder
    private var detail: some View {
        switch detailState {
        case .scanning:
            ProgressView("Scanning For Agent Memory…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.traySurface)
                .transition(.opacity)
        case .nothingFound:
            ContentUnavailableView {
                Label("No Agent Memory Found", systemImage: "brain")
            } description: {
                Text(store.loadError
                    ?? "No harness on this Mac keeps memory or instruction files Runway knows how to read.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.traySurface)
            .transition(.opacity)
        case .editor:
            MemoryEditorView()
                .transition(.opacity)
        }
    }
}

/// The glassy fade under the floating window controls: a frosted material masked by a vertical
/// gradient — fully frosted across the traffic-light clearance, dissolving to nothing over the
/// first rows — so scrolled sidebar content blurs out under the controls instead of drawing
/// hard-edged behind them. Hand-rolled because the native soft scroll-edge effect only renders
/// under a safe-area bar with visible content (the footer qualifies; an empty spacer where the
/// AppKit traffic lights float does not). Purely paint: hit-testing is off.
private struct SidebarTitlebarFade: View {
    let clearance: CGFloat
    /// How far past the clearance the frost takes to dissolve. The sidebar also insets the
    /// scroll indicators by this much so the scrollbar starts below the fade.
    static let dissolve: CGFloat = 24

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: clearance / (clearance + Self.dissolve)),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: clearance + Self.dissolve)
            .allowsHitTesting(false)
    }
}

/// The window-filling behind-window vibrancy the whole Explorer sits on — the "glass desk" under
/// the floating content card. `.sidebar` is the standard vibrant navigation material; under Reduce
/// Transparency the system swaps it for its opaque counterpart automatically.
private struct MemoryWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
