import SwiftUI

/// The Memory Explorer's sidebar: one section per scanned source (harness name, `~`-folded home
/// path, status badge), then that source's documents — the instruction file, per-project
/// `DisclosureGroup`s of index + facts, legacy memories, and read-only database rows. Selection
/// binds straight to `MemoryStore.selectedDocumentID`; the editor pane follows it.
struct MemorySidebarView: View {
    @Environment(MemoryStore.self) private var store
    @Environment(ProviderAccountsStore.self) private var accounts
    /// The Claude project group a "New Memory…" tap targets; non-nil presents the create sheet.
    @State private var newFactProject: MemoryProjectGroup?
    /// Surfaced when the Create Instruction File affordance fails (the store logs the details).
    @State private var actionError: String?

    /// Session-scoped user toggles; a source absent here follows its status default (Ready
    /// expanded, everything else collapsed — the exceptions announce themselves via badge alone).
    @State private var expansionOverrides: [String: Bool] = [:]

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedDocumentID) {
            ForEach(store.sources) { source in
                Section {
                    if isExpanded(source) {
                        sourceRows(for: source)
                    }
                } header: {
                    MemorySourceHeader(
                        source: source,
                        title: title(for: source),
                        isExpanded: isExpanded(source)
                    ) {
                        withAnimation(Motion.snappy) {
                            expansionOverrides[source.id] = !isExpanded(source)
                        }
                    }
                }
            }
            if let warning = store.scanWarning {
                captionRow(warning, style: Theme.notice)
                    .padding(.top, 8)
            }
        }
        .listStyle(.sidebar)
        // The rows paint straight onto the window's vibrancy backdrop (see `MemoryWindowBackdrop`)
        // — no second material panel behind them.
        .scrollContentBackground(.hidden)
        // Re-scans, deletes, and creates animate as list diffs (rows slide/fade into place)
        // instead of the whole sidebar snapping to its new contents.
        .animation(Motion.snappy, value: store.sources)
        .sheet(item: $newFactProject) { project in
            MemoryNewFactSheet(project: project)
        }
        .alert("Something Went Wrong", isPresented: presentingActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sourceRows(for source: MemorySource) -> some View {
        if let instructions = source.instructions {
            MemoryDocumentRow(document: instructions, systemImage: "doc.text")
        } else if source.instructionsUnreadable {
            // The file exists but could not be read — creating over it would destroy it.
            captionRow(
                "The instruction file exists but could not be read. Check the log for details.",
                style: Theme.notice
            )
        } else if canCreateInstructionFile(for: source) {
            // The store knows where the harness expects its instruction file; one click creates it
            // empty so the editor can go straight from "no file yet" to editing. Shown whenever the
            // file is absent — a source can be Ready off other artifacts (project memories, a
            // memory database) and still have no instruction file.
            Button {
                createInstructionFile(for: source)
            } label: {
                Label("Create Instruction File", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .selectionDisabled()
        }
        if case .memoryDisabled(let note) = source.status {
            captionRow(note, style: Theme.notice)
        }
        if case .empty = source.status {
            captionRow("The instruction file is empty.", style: AnyShapeStyle(.secondary))
        }
        ForEach(source.projects) { project in
            projectGroup(project, allowsNewFacts: source.id.hasPrefix("claude:"))
        }
        ForEach(source.legacyDocuments) { document in
            MemoryDocumentRow(document: document, systemImage: "archivebox")
        }
        if !source.databaseDocuments.isEmpty {
            DisclosureGroup {
                ForEach(source.databaseDocuments) { document in
                    MemoryDocumentRow(document: document, systemImage: "lock")
                }
            } label: {
                Label("Memory Database", systemImage: "cylinder.split.1x2")
                    .selectionDisabled()
            }
        }
        if let footnote = source.footnote {
            captionRow(footnote, style: Theme.notice)
        }
    }

    /// One per-project group: the MEMORY.md index, the fact files, and (Claude only — the one
    /// harness whose fact/index format the store can create) the "New Memory…" affordance.
    private func projectGroup(_ project: MemoryProjectGroup, allowsNewFacts: Bool) -> some View {
        DisclosureGroup {
            if let index = project.indexDocument {
                MemoryDocumentRow(document: index, systemImage: "list.bullet")
            }
            ForEach(project.facts) { fact in
                MemoryDocumentRow(document: fact, systemImage: "note.text")
            }
            if allowsNewFacts {
                Button {
                    newFactProject = project
                } label: {
                    Label("New Memory…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName)
                // The verified decoded path when the slug decoder found one, the raw slug otherwise
                // — either way the user can tell two same-named projects apart.
                Text(project.displayPath.map(Self.foldingHome) ?? project.slug)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Container rows carry the ForEach element's implicit tag; without this, the platform
            // can (auto-)select them and the editor is handed an id that is not a document.
            .selectionDisabled()
        }
    }

    private func captionRow(_ text: String, style: AnyShapeStyle) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(style)
            // Explanations wrap; a truncated reason ("use_memorie…") explains nothing.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionDisabled()
    }

    /// Whether the create affordance applies when the instruction file is absent. Memory Disabled
    /// only suppresses it for Grok, whose sole creatable file IS the memory file the disabled
    /// feature ignores; Codex's AGENTS.md is an instruction file independent of its memories
    /// switch, so a memories-off Codex home still gets to create one.
    private func canCreateInstructionFile(for source: MemorySource) -> Bool {
        if case .memoryDisabled = source.status { return !source.id.hasPrefix("grok:") }
        return true
    }

    // MARK: - Actions

    private func createInstructionFile(for source: MemorySource) {
        Task {
            do {
                try await store.createInstructionFile(for: source)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var presentingActionError: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    /// `~`-fold for display, matching the log convention elsewhere.
    static func foldingHome(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func isExpanded(_ source: MemorySource) -> Bool {
        // Ready sources open by default; so does anything with a problem to show — a collapsed
        // section would hide the unreadable-file caption or failure footnote it exists to surface.
        expansionOverrides[source.id]
            ?? (source.status == .ready || source.instructionsUnreadable || source.footnote != nil)
    }

    /// The popover's card rename, honored here: a Claude/Codex home claimed by an account record
    /// shows that card's resolved (possibly custom) title, live — every other source keeps the
    /// harness's static name.
    private func title(for source: MemorySource) -> String {
        let family = String(source.id.prefix(while: { $0 != ":" }))
        guard ProviderAccountID.families.contains(family) else { return source.harness }
        return accounts.resolvedDisplayName(anchoredAt: source.homePath, family: family)
            ?? source.harness
    }
}

/// One selectable document row: icon + title, with the subtitle (index hook or frontmatter
/// description) as a middle-truncated caption underneath.
private struct MemoryDocumentRow: View {
    let document: MemoryDocument
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(document.title, systemImage: systemImage)
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle = document.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .tag(document.id)
    }
}

/// A source's section header: the resolved card title (a rename when the user set one, the harness
/// name otherwise) with its status badge, home path folded to `~` below. Styled as a chip — a
/// grouped-fill background behind a full-weight title — so each account section reads as its own
/// block on the vibrancy backdrop instead of blending into the rows around it. The whole chip is
/// the collapse toggle, with a rotating chevron showing the state.
private struct MemorySourceHeader: View {
    let source: MemorySource
    let title: String
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        // Ready is the norm — only the exceptions carry a badge.
                        if source.status != .ready {
                            MemoryStatusBadge(status: source.status)
                        }
                    }
                    Text(MemorySidebarView.foldingHome(source.homePath))
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.cardFill))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        // The between-sections gap: breathing room above each chip separates one account's block
        // from the previous section's rows.
        .padding(.top, 10)
    }
}

/// The small capsule badge next to a source's harness name: Ready / Empty / No File / Memory
/// Disabled, tinted with the app's shared positive/notice styles.
private struct MemoryStatusBadge: View {
    let status: MemorySourceStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
    }

    private var label: String {
        switch status {
        case .ready: return "Ready"
        case .empty: return "Empty"
        case .missingFile: return "No File"
        case .memoryDisabled: return "Memory Disabled"
        }
    }

    /// Memory Disabled reads at full text contrast on a lightly orange-tinted capsule — the hue
    /// carries the "switched off elsewhere" signal without the badge shouting (a solid orange
    /// chip overpowered the header). The nothing-yet states stay quiet grays.
    private var foreground: AnyShapeStyle {
        switch status {
        case .memoryDisabled: return AnyShapeStyle(.primary)
        case .ready: return Theme.positive
        case .empty, .missingFile: return AnyShapeStyle(.secondary)
        }
    }

    private var background: AnyShapeStyle {
        switch status {
        case .memoryDisabled: return AnyShapeStyle(Color(nsColor: .systemOrange).opacity(0.22))
        case .ready, .empty, .missingFile: return AnyShapeStyle(.quaternary)
        }
    }
}
