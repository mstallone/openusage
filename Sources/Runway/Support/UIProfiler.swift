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
    /// The popover harness (`startDriverIfEnabled`) gates on RUNWAY_UI_PROFILE=1; the Memory-window
    /// harness (`startMemoryDriverIfEnabled`) on RUNWAY_UI_PROFILE_MEMORY=1. Either flag arms the
    /// shared measure/mark/report plumbing — the two drivers never run in one process.
    static let popoverDriverEnabled =
        ProcessInfo.processInfo.environment["RUNWAY_UI_PROFILE"] == "1"
    static let memoryDriverEnabled =
        ProcessInfo.processInfo.environment["RUNWAY_UI_PROFILE_MEMORY"] == "1"
    static let enabled = popoverDriverEnabled || memoryDriverEnabled
    private static let signposter = OSSignposter(
        subsystem: "com.mattstallone.runway", category: "uiprofile"
    )

    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        // The label rides in the signpost message so an Instruments capture can tell
        // `open.layoutSubtree` from `open.orderFront` without cross-referencing the file log.
        let state = signposter.beginInterval("phase", id: signposter.makeSignpostID(), "\(name)")
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            signposter.endInterval("phase", state, "\(name)")
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            AppLog.info("uiprofile", "\(name): \(String(format: "%.2f", ms))ms")
        }
        return try body()
    }

    static func mark(_ message: String) {
        guard enabled else { return }
        // Mirrored as a signpost event so scripted phase boundaries land in Instruments too.
        signposter.emitEvent("mark", "\(message)")
        AppLog.info("uiprofile", message)
    }

    /// For spans `measure` cannot wrap — async work whose start and end live in different calls
    /// (the editor's select→loaded latency, the store's off-main scan). Logs in the same
    /// `name: X.XXms` shape as `measure`, so the aggregation scripts parse both identically.
    static func report(_ name: String, milliseconds: Double) {
        guard enabled else { return }
        signposter.emitEvent("mark", "\(name): \(milliseconds)ms")
        AppLog.info("uiprofile", "\(name): \(String(format: "%.2f", milliseconds))ms")
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
        // Its own flag, not `enabled`: a Memory-window run must not also drive the popover — two
        // concurrent drivers interleave their phase markers and corrupt both aggregations.
        guard popoverDriverEnabled else { return }
        // The harness speaks entirely through info-level log lines; a persisted Warning/Error log
        // floor would silently discard every phase marker and leave profile_ui.sh waiting for a
        // "PHASE done" that never lands. A profiling run is explicitly opted into via the env var,
        // so overriding the floor for this process is the honest behavior (the persisted setting
        // is untouched and applies again on a normal launch).
        AppLog.reloadLevel(.info)
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

            // The setup open gets its own phase so its timings bill to neither the warm-cycles
            // aggregate (12 documented samples, not 13) nor the screen-switch numbers.
            mark("PHASE setup (screen-switch prep)")
            open()
            await pause(1.5)
            mark("PHASE screen-switch (10x)")
            for i in 1...10 {
                let target: PopoverScreen = i.isMultiple(of: 2) ? .dashboard : .customize
                withAnimation(Motion.modeSwitch) { layout.screen = target }
                await pause(1.2)
            }

            mark("PHASE expand (10x caret toggles)")
            // Pick from the applicability-filtered groups the dashboard actually renders: a raw
            // `displayGroups` entry can hold only saved-but-inapplicable On Demand metrics (e.g.
            // Copilot metrics for another plan), whose rendered card has no caret — toggling that
            // provider would animate nothing and produce a fake expand benchmark.
            let expandable = layout.displayGroups(matching: dataStore.isMetricApplicable).first {
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
                // Loud, greppable failure: a run whose expand phase toggled nothing must not read
                // as a clean no-stall result. profile_ui.sh exits non-zero on this marker.
                mark("ERROR expand phase skipped: no rendered provider has a caret")
            }

            mark("PHASE refresh-while-open")
            // A launch-time refresh still fetching a slow provider would make the forced pass skip
            // it (the per-provider in-flight guard), silently excluding the slowest work from this
            // phase. Drain in-flight refreshes first, bounded so a wedged provider can't hang the
            // whole script.
            for _ in 0..<120 where !dataStore.refreshingProviderIDs.isEmpty {
                await pause(0.5)
            }
            if !dataStore.refreshingProviderIDs.isEmpty {
                // Fatal, not advisory: a forced pass that silently skips still-in-flight providers
                // benchmarks less than it claims. profile_ui.sh exits non-zero on this marker.
                mark("ERROR refresh phase aborted: providers still in flight after 60s: \(dataStore.refreshingProviderIDs.sorted().joined(separator: ","))")
            } else {
                await dataStore.refreshAll(force: true)
                mark("refresh returned")
            }
            await pause(3)

            mark("PHASE idle-open (40s)")
            await pause(40)

            mark("PHASE closing")
            close()
            await pause(1)
            mark("PHASE done")
        }
    }

    // MARK: - Memory-window scripted driver

    /// Drives the Memory Explorer window through labeled phases (cold open with the initial scan,
    /// warm open/close cycles — each a full store rebuild by design — selection switches over
    /// file-backed documents, database-row loads, re-scans, an idle soak). `open`/`close` are the
    /// real `StatusItemController`/`MemoryWindowController` chokepoints; selection goes through
    /// `MemoryStore.selectedDocumentID` exactly like a sidebar click. Run with
    /// `script/profile_memory_ui.sh`.
    static func startMemoryDriverIfEnabled(
        open: @escaping () -> Void,
        close: @escaping () -> Void,
        store: @escaping () -> MemoryStore?
    ) {
        guard memoryDriverEnabled else { return }
        // Same floor override as the popover driver: the harness speaks through info-level lines.
        AppLog.reloadLevel(.info)
        mark("memory driver armed; script starts in 4s")
        startStallWatchdog()
        Task { @MainActor in
            await pause(4)

            mark("PHASE mem-cold-open")
            open()
            await waitUntilScanned(store)
            await pause(1)

            mark("PHASE mem-warm-cycles (6x close/open)")
            for i in 1...6 {
                mark("cycle \(i)")
                close()
                await pause(0.6)
                open()
                await waitUntilScanned(store)
                await pause(0.6)
            }

            guard let store = store() else {
                // Loud, greppable failure — profile_memory_ui.sh exits non-zero on this marker.
                mark("ERROR memory driver aborted: no store after open")
                mark("PHASE done")
                return
            }
            let documents = store.sources.flatMap(\.allDocuments)
            let fileDocs = documents.filter { doc in
                if case .file = doc.location { return true }
                return false
            }
            let databaseDocs = documents.filter { $0.kind == .databaseMemory }

            mark("PHASE mem-selection (12x file documents)")
            if fileDocs.count >= 2 {
                let rotation = Array(fileDocs.prefix(6))
                for i in 1...12 {
                    store.selectedDocumentID = rotation[i % rotation.count].id
                    await pause(0.8)
                }
            } else {
                mark("ERROR selection phase skipped: fewer than 2 file documents on this Mac")
            }

            mark("PHASE mem-sqlite (6x database rows)")
            if databaseDocs.count >= 2 {
                let rotation = Array(databaseDocs.prefix(3))
                for i in 1...6 {
                    // Alternate away and back so every database load starts from a non-database
                    // selection, like a user bouncing between a fact and a row.
                    store.selectedDocumentID = i.isMultiple(of: 2)
                        ? fileDocs.first?.id
                        : rotation[i % rotation.count].id
                    await pause(1.0)
                }
            } else {
                mark("mem-sqlite phase skipped: no database rows on this Mac")
            }

            mark("PHASE mem-refresh (3x re-scan)")
            for _ in 1...3 {
                await store.reload()
                await pause(0.5)
            }

            mark("PHASE mem-idle (10s)")
            await pause(10)

            mark("PHASE closing")
            close()
            await pause(0.5)
            mark("PHASE done")
        }
    }

    /// The driver must not race the scan: phase boundaries are only honest once the freshly (re)built
    /// store has finished its initial reload. Bounded so an empty machine cannot hang the script.
    private static func waitUntilScanned(_ store: () -> MemoryStore?) async {
        for _ in 0..<120 {
            if let store = store(), !store.isLoading, !store.sources.isEmpty { return }
            await pause(0.25)
        }
        mark("ERROR scan never finished (or found nothing) within 30s")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
