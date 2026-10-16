import Foundation

// Widget types own their dimensions. Users arrange instances, not their sizes.
enum WidgetKind: String, CaseIterable, Identifiable {
    case clock, media

    var id: String { rawValue }
    var titleKey: L10nKey {
        switch self {
        case .clock: return .widgetClockTitle
        case .media: return .widgetMediaTitle
        }
    }
    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .media: return "play.square.stack"
        }
    }
    var summaryKey: L10nKey {
        switch self {
        case .clock: return .widgetClockDescription
        case .media: return .widgetMediaDescription
        }
    }
    var descriptor: WidgetDescriptor {
        switch self {
        case .clock: return WidgetDescriptor(id: rawValue, span: 2, height: 180)
        case .media: return WidgetDescriptor(id: rawValue, span: 2, height: 180)
        }
    }
}
