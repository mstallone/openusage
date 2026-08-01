import AppIntents
import WidgetKit

/// What a widget instance leads with. Cost keeps the dashboard's honesty rule (dollars when
/// priced, token count when not); Tokens shows the measured counts outright.
enum UsageDisplayMode: String, AppEnum {
    case cost
    case tokens

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Display")
    static let caseDisplayRepresentations: [UsageDisplayMode: DisplayRepresentation] = [
        .cost: "Cost",
        .tokens: "Tokens",
    ]
}

/// Per-instance widget settings (long-press → Edit Widget), so a lock screen slot can show
/// token counts while another shows spend.
struct UsageConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage Display"
    static let description = IntentDescription("Choose whether the widget shows cost or token counts.")

    @Parameter(title: "Show", default: .cost)
    var display: UsageDisplayMode
}
