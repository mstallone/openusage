import AppKit
import SwiftUI
import os

// The UI performance harness. Env-gated behind RUNWAY_UI_PROFILE=1 and inert otherwise: `enabled`
// is read once, every entry point guards on it, and a release user never pays more than that check.
// Run it with `script/profile_ui.sh`, which builds, drives the scripted phases below, and prints a
// stats summary to compare against the recorded baseline (see docs/debugging.md).
//
// Three pieces:
//  - measure/mark: wall-clock phase timing logged to the app log, mirrored as os_signpost intervals
//    so an Instruments capture can line them up with Time Profiler samples.
//  - a main-thread stall watchdog: an 8ms main-actor heartbeat that logs any gap > 50ms. Note this
//    measures main-QUEUE latency (how long an async main-actor task waits), not dropped frames —
//    the runloop can starve the dispatch queue during animations while frames still land.
//  - a scripted driver that walks the UI through labeled phases (cold open, warm open/close cycles,
//    screen switches, card expands, forced refresh with the panel open, idle-open) so external
//    `sample` captures can be timed against the log markers.
@MainActor
enum UIProfiler {
    static let enabled = ProcessInfo.processInfo.environment["RUNWAY_UI_PROFILE"] == "1"
    private static let signposter = OSSignposter(
        subsystem: "com.mattstallone.runway", category: "uiprofile"
    )

    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let state = signposter.beginInterval("phase", id: signposter.makeSignpostID())
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            signposter.endInterval("phase", state)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            AppLog.info("uiprofile", "\(name): \(String(format: "%.2f", ms))ms")
        }
        return try body()
    }

    static func mark(_ message: String) {
        guard enabled else { return }
        AppLog.info("uiprofile", message)
    }

    // MARK: - Stall watchdog

    /// Logs main-actor scheduling gaps. An 8ms sleep that resumes late by more than ~40ms means the
    /// main thread was busy (or the runloop starved) for that long — a hitch the user can see.
    private static func startStallWatchdog() {
        Task { @MainActor in
            var last = CFAbsoluteTimeGetCurrent()
            while true {
                try? await Task.sleep(for: .milliseconds(8))
                let now = CFAbsoluteTimeGetCurrent()
                let gap = now - last
                last = now
                if gap > 0.050 {
                    AppLog.info("uiprofile", "STALL \(Int(gap * 1000))ms")
                }
            }
        }
    }

    // MARK: - Scripted driver

    /// Drives the popover through labeled phases. `open`/`close` come from `StatusItemController`'s
    /// real show/hide chokepoints so every scripted action exercises the user-facing code path.
    static func startDriverIfEnabled(
        open: @escaping () -> Void,
        close: @escaping () -> Void,
        layout: LayoutStore,
        dataStore: WidgetDataStore
    ) {
        guard enabled else { return }
        mark("driver armed; script starts in 6s")
        startStallWatchdog()
        Task { @MainActor in
            await pause(6)

            mark("PHASE cold-open")
            open()
            await pause(2.5)
            close()
            await pause(1.5)

            mark("PHASE warm-cycles (12x open/close)")
            for i in 1...12 {
                mark("cycle \(i) open")
                open()
                await pause(1.0)
                close()
                await pause(0.5)
            }

            mark("PHASE screen-switch (10x)")
            open()
            await pause(1.5)
            for i in 1...10 {
                let target: PopoverScreen = i.isMultiple(of: 2) ? .dashboard : .customize
                withAnimation(Motion.modeSwitch) { layout.screen = target }
                await pause(1.2)
            }

            mark("PHASE expand (10x caret toggles)")
            let expandable = layout.displayGroups.first {
                $0.hasExpandedMetrics || !$0.provider.visibleLinks.isEmpty
            }?.provider.id
            if let expandable {
                for i in 1...10 {
                    let expanding = !i.isMultiple(of: 2)
                    withAnimation(Motion.spring) {
                        MenuBarPopover.coAnimateExpansion?(expandable, expanding)
                        _ = layout.setProviderExpanded(expanding, for: expandable)
                    }
                    await pause(1.2)
                }
            } else {
                mark("no expandable provider found")
            }

            mark("PHASE refresh-while-open")
            await dataStore.refreshAll(force: true)
            mark("refresh returned")
            await pause(3)

            mark("PHASE idle-open (40s)")
            await pause(40)

            mark("PHASE closing")
            close()
            await pause(1)
            mark("PHASE done")
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
