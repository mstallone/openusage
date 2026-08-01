import SwiftUI

/// Shared scaffolding for the Settings window's panes — the same caption-header-over-card idiom the
/// popover's Customize screen uses (and the in-popover Settings screen used before it moved here),
/// so the window keeps Runway's one visual language.

/// A caption header over a rounded card of rows. The header is inset 8pt so it aligns with the rows'
/// content, matching how Customize lines its provider headers up with the card rows.
struct SettingsSection<Rows: View>: View {
    private let title: String
    private let rows: Rows
    private let density = DensitySetting.compact

    init(_ title: String, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                rows
            }
            .cardSurface()
        }
    }
}

/// One settings row: label on the leading edge, the control on the trailing edge — the System
/// Settings shape, with the same insets as a Customize metric row.
struct SettingsRow<Control: View>: View {
    private let label: String
    private let control: Control
    private let density = DensitySetting.compact

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}

/// An inline orange caption under a row — the shared notice idiom for error lines and "this setting
/// is paused" captions.
struct SettingsInlineNotice: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet explanatory caption under a row (secondary, not a warning).
struct SettingsCaption: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A trailing popup picker that hugs its selection, shared by every pickable settings row.
struct SettingsMenuPicker<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [Value]
    private let label: (Value) -> String

    init(_ selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// A full-width button row inside a card — the "Check for Updates…" idiom. The frame goes on the
/// label so the glass background stretches the full row width instead of hugging the text. (Glass on
/// macOS 26+, bordered fallback on macOS 15.)
struct SettingsCardButton: View {
    private let title: String
    private let action: () -> Void
    private let density = DensitySetting.compact

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}
