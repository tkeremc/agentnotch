import Foundation

// Widget types own their dimensions. Users arrange instances, not their sizes.
enum WidgetKind: String, CaseIterable, Identifiable {
    case clock, media, codex

    var id: String { rawValue }
    var titleKey: L10nKey {
        switch self {
        case .clock: return .widgetClockTitle
        case .media: return .widgetMediaTitle
        case .codex: return .widgetCodexTitle
        }
    }
    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .media: return "play.square.stack"
        case .codex: return "terminal"
        }
    }
    var summaryKey: L10nKey {
        switch self {
        case .clock: return .widgetClockDescription
        case .media: return .widgetMediaDescription
        case .codex: return .widgetCodexDescription
        }
    }
    var descriptor: WidgetDescriptor {
        switch self {
        case .clock: return WidgetDescriptor(id: rawValue, span: 2, height: 180)
        case .media: return WidgetDescriptor(id: rawValue, span: 2, height: 180)
        case .codex: return WidgetDescriptor(id: rawValue, span: 2, height: 180)
        }
    }
}
