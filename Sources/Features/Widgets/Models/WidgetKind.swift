import Foundation

// Widget types own their dimensions. Users arrange instances, not their sizes.
enum WidgetKind: String, CaseIterable, Identifiable {
    case clock

    var id: String { rawValue }
    var title: String {
        switch self { case .clock: return "Saat" }
    }
    var symbol: String {
        switch self { case .clock: return "clock" }
    }
    var summary: String {
        switch self { case .clock: return "Yerel saat, tarih ve gün" }
    }
    var descriptor: WidgetDescriptor {
        switch self {
        case .clock: return WidgetDescriptor(id: rawValue, span: 1, height: 148)
        }
    }
}
