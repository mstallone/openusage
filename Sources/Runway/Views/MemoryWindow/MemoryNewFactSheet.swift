import SwiftUI

/// The "New Memory…" sheet for a Claude project group: title, description, and the fact type the
/// frontmatter template records. Create writes the fact file plus its MEMORY.md index line through
/// the store, then selects the new document so the editor opens straight onto it.
struct MemoryNewFactSheet: View {
    @Environment(MemoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: MemoryProjectGroup

    @State private var name = ""
    @State private var descriptionText = ""
    @State private var factType = "user"
    @State private var isCreating = false
    @State private var creationError: String?

    /// The observed `metadata.type` values in Claude's fact frontmatter.
    private static let factTypes = ["user", "feedback", "project", "reference"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Memory")
                    .font(.title3.weight(.semibold))
                Text("In \(project.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $name)
                TextField("Description", text: $descriptionText)
                Picker("Type", selection: $factType) {
                    ForEach(Self.factTypes, id: \.self) { type in
                        Text(type.capitalized).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .textFieldStyle(.roundedBorder)
            if let creationError {
                Text(creationError)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .glassButtonStyle(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        isCreating = true
        creationError = nil
        Task {
            do {
                let newDocumentID = try await store.createFact(
                    in: project,
                    name: trimmedName,
                    description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: factType
                )
                store.selectedDocumentID = newDocumentID
                dismiss()
            } catch {
                creationError = error.localizedDescription
                isCreating = false
            }
        }
    }
}
