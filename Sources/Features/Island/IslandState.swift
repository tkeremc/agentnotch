import AppKit
import Combine

enum IslandPage {
    case home, files
}

@MainActor
final class IslandState: ObservableObject {
    @Published var page: IslandPage = .home {
        didSet {
            guard oldValue != page else { return }
            pageAfterCollapse = nil
            if page == .files { isEditingWidgets = false }
            pageChanged?()
        }
    }
    @Published private(set) var isIncomingDrag = false
    @Published var isDropTargeted = false
    @Published var isOutgoingDrag = false
    @Published var hasFileDrag = false
    @Published var dragHintProgress: CGFloat = 0
    @Published var shelfHeight: CGFloat = 240
    @Published var pageProgress: CGFloat = 0
    private var pageBeforeDrag: IslandPage?
    private var pageAfterCollapse: IslandPage?
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
    // The controller advances both geometry and hit testing from the same value.
    var shelfWidth: CGFloat { layout.width }
    var expandedWidth: CGFloat { layout.width }
    var contentHeight: CGFloat { layout.contentHeight + (shelfHeight - layout.contentHeight) * pageProgress }
    // Fade through the background rather than superimposing two readable pages.
    var homePageOpacity: CGFloat { max(0, 1 - 2 * pageProgress) }
    var filesPageOpacity: CGFloat { max(0, 2 * pageProgress - 1) }
    var holdsOpen: Bool { isEditingWidgets || isIncomingDrag || isOutgoingDrag }
    var openSettings: (() -> Void)?
    var editingChanged: (() -> Void)?
    var pageChanged: (() -> Void)?
    var filesDropped: (([URL]) -> Bool)?
    var dropTargetChanged: ((Bool) -> Void)?
    var outgoingChanged: ((Bool) -> Void)?

    func beginIncomingDrag() {
        guard !isOutgoingDrag, !isIncomingDrag else { return }
        pageBeforeDrag = pageAfterCollapse ?? page
        pageAfterCollapse = nil
        isIncomingDrag = true
        page = .files
    }

    func endIncomingDrag(accepted: Bool = false) {
        let previous = pageBeforeDrag
        pageBeforeDrag = nil
        isIncomingDrag = false
        isDropTargeted = false
        if accepted {
            pageAfterCollapse = nil
        } else if let previous {
            pageAfterCollapse = previous
        }
        restorePageAfterCollapse()
    }

    func selectPage(_ selected: IslandPage) {
        pageAfterCollapse = nil
        page = selected
    }

    func restorePageAfterCollapse() {
        guard !expanded, progress == 0, contentProgress == 0,
              let previous = pageAfterCollapse else { return }
        pageAfterCollapse = nil
        page = previous
    }
    var showsDragHint: Bool { hasFileDrag && !expanded && !isOutgoingDrag }
    static let dragHintHeight: CGFloat = 26
    var surfaceWidth: CGFloat {
        let restingWidth = collapsedWidth + 24 * dragHintProgress
        return restingWidth + (expandedWidth - restingWidth) * progress
    }
    var surfaceHeight: CGFloat {
        topBand + contentHeight * progress
            + (Self.dragHintHeight * dragHintProgress - collapsedBottomInset) * (1 - progress)
    }
    var canvasSize: NSSize {
        NSSize(width: max(layout.width, collapsedWidth + 24) + 24,
               height: topBand + max(layout.contentHeight, shelfHeight, Self.dragHintHeight) + 12)
    }
}
