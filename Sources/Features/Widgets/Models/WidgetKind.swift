import Foundation

// Widget types own their dimensions. Users arrange instances, not their sizes.
enum WidgetKind: String, CaseIterable, Identifiable {
    case clock

    var id: String { rawValue }
    var titleKey: L10nKey {
        switch self { case .clock: return .widgetClockTitle }
    }
    var symbol: String {
        switch self { case .clock: return "clock" }
    }
    var summaryKey: L10nKey {
        switch self { case .clock: return .widgetClockDescription }
    }
    var descriptor: WidgetDescriptor {
        switch self {
        case .clock: return WidgetDescriptor(id: rawValue, span: 1, height: 148)
        }
    }
}
