import AppKit
import Combine

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var progress: CGFloat = 0
    @Published var contentProgress: CGFloat = 0
    @Published var topBand: CGFloat = 32
    @Published var collapsedBottomInset: CGFloat = 0
    @Published var collapsedWidth: CGFloat = 200
    @Published var layout = WidgetDrawerLayout(widgets: [WidgetKind.clock.descriptor], maximumWidth: 880,
                                              minimumWidth: WidgetDrawerLayout.minimumWidth(collapsedWidth: 200),
                                              maximumHeight: 560, editing: false)
    @Published var isEditingWidgets = false {
        didSet { if oldValue != isEditingWidgets { editingChanged?() } }
    }
    var expandedWidth: CGFloat { layout.width }
    var contentHeight: CGFloat { layout.contentHeight }
    var openSettings: (() -> Void)?
    var editingChanged: (() -> Void)?
    var surfaceWidth: CGFloat { collapsedWidth + (expandedWidth - collapsedWidth) * progress }
    var surfaceHeight: CGFloat { topBand + contentHeight * progress - collapsedBottomInset * (1 - progress) }
    var canvasSize: NSSize { NSSize(width: expandedWidth + 24, height: topBand + contentHeight + 12) }
}
