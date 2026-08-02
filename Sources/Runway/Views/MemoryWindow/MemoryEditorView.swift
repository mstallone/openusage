import AppKit
import SwiftUI

/// The editor chose Save but had no document to write — surfaced loudly so a "Save" that wrote
/// nothing can never quietly approve a close or a refresh.
enum MemoryEditorError: Error, LocalizedError {
    case noSavableDocument

    var errorDescription: String? {
        "The memory to save is no longer available, so nothing was written."
    }
}

/// Dirty-state bridge between the editor view and the AppKit window controller. The controller
/// can't reach into SwiftUI `@State`, so the editor mirrors its unsaved-changes flag here and
/// installs the two hooks the window lifecycle needs: save-before-close for the dirty-close prompt,
/// and the external-change re-stat `windowDidBecomeKey` triggers.
@MainActor
@Observable
final class MemoryEditorState {
    static let shared = MemoryEditorState()

    /// Whether the editor holds unsaved changes — the controller's `windowShouldClose` prompt keys
    /// off this.
    var isDirty = false
    /// Saves the dirty buffer in place; installed while the editor is mounted. The dirty-close
    /// prompt's "Save" calls it (an explicit save, so it overwrites even if the disk copy moved).
    var saveDirtyDocument: (@MainActor () async throws -> Void)?
    /// Re-stats the loaded file against the buffer; the controller calls it from
    /// `windowDidBecomeKey` so edits made in another app surface as soon as the window returns.
    var recheckExternalChange: (@MainActor () async -> Void)?

    func reset() {
        isDirty = false
        saveDirtyDocument = nil
        recheckExternalChange = nil
    }
}

/// The Memory Explorer's detail pane: a monospaced editor over the selected document with explicit
/// save only (⌘S / the Save button — these files are shared with live agent processes, so no
/// autosave). Database rows render read-only. The view stays mounted across selection changes so a
/// dirty buffer can prompt Save / Discard / Cancel before the selection actually moves, and it
/// keeps the loaded modification date to catch external changes: disk newer + clean reloads
/// silently, disk newer + dirty raises the Reload / Overwrite banner.
struct MemoryEditorView: View {
    @Environment(MemoryStore.self) private var store

    /// The document the buffer below belongs to — follows `store.selectedDocumentID`, but only
    /// after the dirty prompt (if any) resolves.
    @State private var loadedDocumentID: String?
    @State private var text = ""
    /// The on-disk baseline the dirty flag compares against; reset on load and save.
    @State private var savedText = ""
    /// The file's modification date at load/save time; the conflict checks compare fresh stats to it.
    @State private var loadedModificationDate: Date?
    /// Bumped by every `loadDocument`; an async read only lands if its generation is still current,
    /// so a stale read can never clobber a newer document's buffer.
    @State private var loadGeneration = 0
    /// True from `loadDocument` until its read lands. The editor is disabled meanwhile, so the user
    /// cannot type into an empty buffer that a slow read is about to replace — and cannot save that
    /// fragment over the full file.
    @State private var isLoadingContent = false
    @State private var loadError: String?
    /// Disk newer + dirty: the Reload / Overwrite banner is up.
    @State private var hasConflict = false
    /// A selection change that arrived while the buffer was dirty, held until the user decides.
    /// Wrapped so "switch to no selection" (nil) is distinguishable from "nothing pending".
    @State private var pendingSelection: PendingSelection?
    @State private var isPromptingDirtySwitch = false
    @State private var isConfirmingDelete = false
    /// Save/delete failures, surfaced as a friendly alert (the store already logged the details).
    @State private var actionError: String?

    private struct PendingSelection {
        var documentID: String?
    }

    var body: some View {
        content
            .background(Theme.traySurface)
            .onAppear {
                MemoryEditorState.shared.saveDirtyDocument = { try await performSave(bypassingConflictCheck: true) }
                MemoryEditorState.shared.recheckExternalChange = { await recheckExternalChange() }
                syncSelection(store.selectedDocumentID)
            }
            .onDisappear { MemoryEditorState.shared.reset() }
            .onChange(of: store.selectedDocumentID) { _, newID in syncSelection(newID) }
            .onChange(of: text) { syncDirtyFlag() }
            .confirmationDialog("Save Changes?", isPresented: $isPromptingDirtySwitch) {
                Button("Save") {
                    Task {
                        do {
                            try await performSave(bypassingConflictCheck: true)
                            switchToPendingSelection()
                        } catch {
                            actionError = error.localizedDescription
                            pendingSelection = nil
                        }
                    }
                }
                Button("Discard Changes", role: .destructive) { switchToPendingSelection() }
                Button("Cancel", role: .cancel) { pendingSelection = nil }
            } message: {
                Text("This memory has unsaved changes.")
            }
            .confirmationDialog("Delete This Memory?", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    Task { await deleteFact() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the fact file and its MEMORY.md index line.")
            }
            .alert("Something Went Wrong", isPresented: presentingActionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let document {
            editor(for: document)
        } else if loadedDocumentID != nil {
            // The selection outlived its document (a refresh dropped it, or the file vanished).
            ContentUnavailableView {
                Label("Memory Not Found", systemImage: "questionmark.folder")
            } description: {
                Text("This memory is no longer on disk.")
            }
        } else {
            ContentUnavailableView {
                Label("No Memory Selected", systemImage: "brain")
            } description: {
                Text("Select a memory in the sidebar to view or edit it.")
            }
        }
    }

    private func editor(for document: MemoryDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: document)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if hasConflict {
                conflictBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            if document.isEditable {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // No typing until the initial read lands: keystrokes made into the still-empty
                    // buffer would be replaced by the arriving disk content (or saved over the full
                    // file as a fragment).
                    .disabled(isLoadingContent)
                    .opacity(isLoadingContent ? 0 : 1)
            } else {
                // Read-only rendering for database rows: the composed raw-memory-above-rollout-
                // summary text the store loads, selectable but never a live buffer.
                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .opacity(isLoadingContent ? 0 : 1)
            }
        }
        // One scoped clock for the editor's own state motion: the conflict banner and load-error
        // rows slide in under the header, and arriving content fades in over the (rare) visible
        // gap of a slow read instead of popping. Selection swaps stay content-driven — quick loads
        // flip `isLoadingContent` within a frame or two, which reads as a subtle crossfade.
        .animation(Motion.snappy, value: hasConflict)
        .animation(Motion.snappy, value: loadError)
        .animation(Motion.modeSwitch, value: isLoadingContent)
    }

    private func header(for document: MemoryDocument) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(document.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !document.isEditable {
                        readOnlyBadge
                    }
                }
                Text(MemorySidebarView.foldingHome(revealPath(for: document)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if document.kind == .fact {
                Button("Delete…", role: .destructive) { isConfirmingDelete = true }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: revealPath(for: document))
                ])
            }
            if document.isEditable {
                Button("Save") {
                    Task {
                        do {
                            try await performSave(bypassingConflictCheck: false)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                .glassButtonStyle(prominent: true)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
            }
        }
    }

    private var readOnlyBadge: some View {
        Label("Read-Only", systemImage: "lock.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }

    /// Disk newer + dirty: the buffer and the file have both moved. Reload discards the buffer for
    /// the disk copy; Overwrite saves the buffer over it.
    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.notice)
            Text("This file changed on disk while you were editing.")
                .font(.caption)
            Spacer(minLength: 8)
            Button("Reload") { loadDocument(id: loadedDocumentID) }
            Button("Overwrite") {
                Task {
                    do {
                        try await performSave(bypassingConflictCheck: true)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .cardSurface()
    }

    // MARK: - State

    private var document: MemoryDocument? {
        loadedDocumentID.flatMap { store.document(withID: $0) }
    }

    private var isDirty: Bool {
        document?.isEditable == true && text != savedText
    }

    private func syncDirtyFlag() {
        MemoryEditorState.shared.isDirty = isDirty
    }

    private var presentingActionError: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    /// The path Reveal in Finder targets (and the header caption shows): the file itself, or the
    /// database file a read-only row lives in.
    private func revealPath(for document: MemoryDocument) -> String {
        switch document.location {
        case .file(let path): return path
        case .sqliteRow(let dbPath, _): return dbPath
        }
    }

    // MARK: - Selection

    /// Follow the sidebar's selection — unless the buffer is dirty, in which case hold the sidebar
    /// on the loaded document and prompt before the switch actually happens.
    private func syncSelection(_ newID: String?) {
        guard newID != loadedDocumentID else { return }
        if isDirty {
            pendingSelection = PendingSelection(documentID: newID)
            isPromptingDirtySwitch = true
            // Re-entrant onChange: the revert lands back here and hits the early return above.
            store.selectedDocumentID = loadedDocumentID
        } else {
            loadDocument(id: newID)
        }
    }

    private func switchToPendingSelection() {
        guard let pending = pendingSelection else { return }
        pendingSelection = nil
        store.selectedDocumentID = pending.documentID
        loadDocument(id: pending.documentID)
    }

    private func loadDocument(id: String?) {
        loadGeneration += 1
        let generation = loadGeneration
        loadedDocumentID = id
        text = ""
        savedText = ""
        loadedModificationDate = nil
        isLoadingContent = false
        loadError = nil
        hasConflict = false
        syncDirtyFlag()
        guard let id else { return }
        guard let document = store.document(withID: id) else {
            // A selection value that never resolved to a document (e.g. a container row the
            // platform auto-selected) reads as no selection, not as a vanished memory.
            loadedDocumentID = nil
            return
        }
        isLoadingContent = true
        let loadStart = CFAbsoluteTimeGetCurrent()
        Task {
            do {
                let content = try await store.loadContent(document)
                // A newer load may have started while the read ran (selection moved, or the same
                // document was reloaded); a stale result must not clobber the newer buffer.
                guard loadGeneration == generation else { return }
                UIProfiler.report(
                    document.kind == .databaseMemory ? "memory.dbRowLoad" : "memory.fileLoad",
                    milliseconds: (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                )
                isLoadingContent = false
                text = content.text
                savedText = content.text
                loadedModificationDate = content.modificationDate
                syncDirtyFlag()
            } catch {
                guard loadGeneration == generation else { return }
                isLoadingContent = false
                loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Save / delete / external changes

    /// The one save path. The plain ⌘S/save-button call re-stats first and diverts to the conflict
    /// banner if the disk copy moved; the banner's Overwrite, the dirty prompts' Save, and the
    /// controller's close-prompt Save bypass that check — the user just chose explicitly.
    ///
    /// No savable document (it vanished from the store, or the initial read hasn't landed) throws
    /// instead of returning: a caller that chose Save must never be told it succeeded when nothing
    /// was written.
    private func performSave(bypassingConflictCheck: Bool) async throws {
        guard let document, document.isEditable, !isLoadingContent else {
            AppLog.error(.memory, "save rejected: no savable document behind the editor buffer")
            throw MemoryEditorError.noSavableDocument
        }
        if !bypassingConflictCheck, let loaded = loadedModificationDate {
            let current = await store.currentModificationDate(of: document)
            if let current, current != loaded {
                hasConflict = true
                return
            }
        }
        try await store.save(document, text: text)
        savedText = text
        loadedModificationDate = await store.currentModificationDate(of: document)
        hasConflict = false
        syncDirtyFlag()
    }

    private func deleteFact() async {
        guard let document, document.kind == .fact else { return }
        // Deleting IS the user's decision about the buffer — mark it clean so the store's
        // selection-clear can't re-trigger the dirty prompt mid-delete.
        savedText = text
        syncDirtyFlag()
        do {
            try await store.deleteFact(document)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// The `windowDidBecomeKey` re-stat: disk newer + clean reloads silently, disk newer + dirty
    /// raises the banner. Database rows have no file to stat.
    private func recheckExternalChange() async {
        guard let document, case .file = document.location else { return }
        let current = await store.currentModificationDate(of: document)
        guard current != loadedModificationDate else { return }
        if isDirty {
            hasConflict = true
        } else {
            loadDocument(id: document.id)
        }
    }
}
