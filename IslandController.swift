import AppKit
import Combine
import QuartzCore
import SwiftUI

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

struct WidgetDescriptor: Equatable {
    let id: String
    let span: Int
    let height: CGFloat
}

// One source of truth for card positions, scroll height and native panel size.
// Packing is ordered: a wide widget starts a new row if it cannot fit.
struct WidgetDrawerLayout: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let frame: CGRect
        let widgetHeight: CGFloat
    }

    static let maximumWidth: CGFloat = 880
    static let cellWidth: CGFloat = 201
    static let inset: CGFloat = 20
    static let gap: CGFloat = 12
    static let toolbarButtonSize: CGFloat = 28
    static let toolbarGap: CGFloat = 8
    static let topPadding: CGFloat = 12
    static let editingControlsHeight: CGFloat = 36
    static let catalogHeight: CGFloat = 110

    let width: CGFloat
    let columns: Int
    let items: [Item]
    let gridHeight: CGFloat
    let contentHeight: CGFloat
    var viewportHeight: CGFloat { max(0, contentHeight - Self.topPadding) }

    static func minimumWidth(collapsedWidth: CGFloat) -> CGFloat {
        // Leave the centered physical notch clear of the right-hand controls.
        collapsedWidth + 2 * (inset + 2 * toolbarButtonSize + toolbarGap + 8)
    }

    init(widgets: [WidgetDescriptor], maximumWidth: CGFloat, minimumWidth: CGFloat = 0,
         maximumHeight: CGFloat, editing: Bool) {
        let limit = max(1, min(Self.maximumWidth, maximumWidth))
        let capacity = max(1, min(4, Int((limit - 2 * Self.inset + Self.gap) / (Self.cellWidth + Self.gap))))
        var occupied = 0
        var requiredColumns = 1
        for widget in widgets {
            let span = max(1, min(capacity, widget.span))
            if occupied + span > capacity { occupied = 0 }
            occupied += span
            requiredColumns = max(requiredColumns, occupied)
        }
        columns = requiredColumns
        let gridWidth = CGFloat(columns) * Self.cellWidth + CGFloat(columns - 1) * Self.gap
        let contentMinimum: CGFloat = widgets.isEmpty ? 300 : 0
        let catalogMinimum: CGFloat = editing ? 290 : 0
        width = min(limit, max(gridWidth + 2 * Self.inset, minimumWidth, contentMinimum, catalogMinimum))
        let availableWidth = max(1, width - 2 * Self.inset)
        let cellWidth = max(1, min(Self.cellWidth, (availableWidth - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)))
        let leadingInset = (width - (CGFloat(columns) * cellWidth + CGFloat(columns - 1) * Self.gap)) / 2
        var column = 0
        var rowY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var placed: [Item] = []
        for widget in widgets {
            let span = max(1, min(columns, widget.span))
            if column + span > columns {
                rowY += rowHeight + Self.gap
                rowHeight = 0
                column = 0
            }
            let height = widget.height + (editing ? Self.editingControlsHeight : 0)
            placed.append(Item(id: widget.id, frame: CGRect(
                x: leadingInset + CGFloat(column) * (cellWidth + Self.gap), y: rowY,
                width: cellWidth * CGFloat(span) + Self.gap * CGFloat(span - 1), height: height
            ), widgetHeight: widget.height))
            rowHeight = max(rowHeight, height)
            column += span
        }
        items = placed
        gridHeight = widgets.isEmpty ? 148 : rowY + rowHeight
        contentHeight = min(maximumHeight, Self.topPadding + gridHeight + Self.inset
                            + (editing ? Self.catalogHeight : 0))
    }
}

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

// A critically damped spring settles without bouncing past the notch edges.
// Retargeting preserves position and velocity, including during quick hovers.
struct IslandMotion {
    var progress: Double = 0
    var velocity: Double = 0

    mutating func advance(toward target: Double, elapsed: Double, frequency: Double) {
        let displacement = progress - target
        let weight = velocity + frequency * displacement
        let wave = displacement + weight * elapsed
        let attenuation = exp(-frequency * elapsed)
        progress = target + attenuation * wave
        velocity = attenuation * (weight - frequency * wave)
        if abs(progress - target) < 0.002 && abs(velocity) < 0.04 {
            self = IslandMotion(progress: target)
        }
    }
}

// Geometry finishes before content reveals from top to bottom. Closing hides
// content and shrinks the surface together; both remain continuous on reversal.
struct IslandTransition {
    var surface = IslandMotion()
    var content = IslandMotion()

    init(expanded: Bool = false) {
        surface = IslandMotion(progress: expanded ? 1 : 0)
        content = IslandMotion(progress: expanded ? 1 : 0)
    }

    mutating func advance(expanded: Bool, elapsed: Double, speed: Double = 1) {
        let elapsed = elapsed * speed
        if expanded {
            surface.advance(toward: 1, elapsed: elapsed, frequency: 44)
            content.advance(toward: surface.progress == 1 ? 1 : 0,
                            elapsed: elapsed, frequency: 60)
        } else {
            content.advance(toward: 0, elapsed: elapsed, frequency: 76)
            surface.advance(toward: 0, elapsed: elapsed, frequency: 48)
        }
    }

    func isSettled(expanded: Bool) -> Bool {
        let target = expanded ? 1.0 : 0.0
        return surface.progress == target && surface.velocity == 0
            && content.progress == target && content.velocity == 0
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HoverHostingView: NSHostingView<IslandView> {
    var hoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

@MainActor
final class IslandController: NSObject {
    private let state = IslandState()
    private let settings: NotchSettings
    private var subscriptions = Set<AnyCancellable>()
    private let panel: IslandPanel
    private var screen: NSScreen?
    private var topInset: CGFloat = 0
    private var pendingHover: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pointerInside = false
    private var transition = IslandTransition()
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    init(settings: NotchSettings, openSettings: @escaping () -> Void) {
        self.settings = settings
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        state.openSettings = openSettings
        state.editingChanged = { [weak self] in self?.editingChanged() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.colorSpace = .sRGB
        panel.alphaValue = 1
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        positionOnScreen()
        let view = HoverHostingView(rootView: IslandView(state: state, settings: settings))
        // The controller owns the panel's size. SwiftUI's automatic window
        // min/max constraints otherwise feed animated layout back into AppKit.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // Native tracking describes the rectangular canvas, while activation
        // also includes the physical notch and the screen's top edge.
        view.hoverChanged = { [weak self] _ in self?.pointerMoved() }
        // A hosting view used directly as window content also participates in
        // SwiftUI's animated window sizing. A plain AppKit container keeps that
        // mechanism separate from the controller's explicit frame animation.
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        view.frame = container.bounds
        container.addSubview(view)
        panel.contentView = container
        settings.$isEnabled.removeDuplicates().dropFirst().sink { [weak self] enabled in
            if enabled { self?.show() } else { self?.hide() }
        }.store(in: &subscriptions)
        settings.$animationsEnabled.dropFirst().sink { [weak self] enabled in
            guard let self, !enabled else { return }
            self.finishTransition()
        }.store(in: &subscriptions)
        // @Published emits before assignment, so pass the new list explicitly.
        settings.$widgets.dropFirst().sink { [weak self] widgets in
            self?.updateDrawerLayout(widgets: widgets)
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.positionOnScreen() }
        }
    }

    func show() {
        pendingHover?.cancel()
        stopAnimation()
        transition = IslandTransition()
        state.progress = 0
        state.contentProgress = 0
        state.expanded = false
        pointerInside = false
        positionOnScreen()
        startMouseMonitoring()
        panel.orderFrontRegardless()
        pointerMoved()
    }

    func hide() {
        panel.orderOut(nil)
        state.isEditingWidgets = false
        pendingHover?.cancel()
        stopAnimation()
        state.expanded = false
        state.progress = 0
        state.contentProgress = 0
        transition = IslandTransition()
        pointerInside = false
        stopMouseMonitoring()
    }

    private func startMouseMonitoring() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            self?.pointerMoved()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.pointerMoved()
            return event
        }
    }

    private func stopMouseMonitoring() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func positionOnScreen() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let notchHeight = screen.safeAreaInsets.top
        state.topBand = notchHeight > 0 ? notchHeight : 32
        state.collapsedBottomInset = 3 / screen.backingScaleFactor
        topInset = notchHeight > 0 ? 0 : 8
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            // Inset each edge by 2 pt to visually match the physical notch.
            state.collapsedWidth = right.minX - left.maxX - 4
        } else {
            state.collapsedWidth = 190
        }
        updateDrawerLayout(widgets: settings.widgets)
    }

    private func updateDrawerLayout(widgets: [WidgetKind]) {
        guard let screen else { return }
        let maximumHeight = max(1, min(560, screen.frame.height - topInset - state.topBand - 32))
        state.layout = WidgetDrawerLayout(widgets: widgets.map(\.descriptor), maximumWidth: screen.frame.width - 56,
                                          minimumWidth: WidgetDrawerLayout.minimumWidth(collapsedWidth: state.collapsedWidth),
                                          maximumHeight: maximumHeight, editing: state.isEditingWidgets)
        let size = state.canvasSize
        // The native window never resizes during hover. Only the black surface
        // inside this transparent canvas changes, so it cannot clip the spring.
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        ), display: true)
        pointerMoved()
        updateMousePassthrough()
    }

    private func editingChanged() {
        pendingHover?.cancel()
        updateDrawerLayout(widgets: settings.widgets)
        guard panel.isVisible else { return }
        if state.isEditingWidgets {
            setExpanded(true)
        } else {
            // Explicitly reschedule even if the pointer was already outside.
            hover(hoverFrame.contains(NSEvent.mouseLocation))
        }
    }

    private var surfaceFrame: NSRect {
        NSRect(x: panel.frame.midX - state.surfaceWidth / 2,
               y: panel.frame.maxY - state.surfaceHeight,
               width: state.surfaceWidth, height: state.surfaceHeight)
    }

    private var hoverFrame: NSRect {
        guard let screen else { return surfaceFrame }
        // The pointer can stop at the hardware notch's lower edge or exactly
        // on maxY, which NSRect.contains normally excludes. Add a small buffer
        // around the notch and extend through the upper screen boundary.
        let activationWidth = state.collapsedWidth + 64
        let activationBottom = panel.frame.maxY - state.topBand - 10
        let activation = NSRect(
            x: screen.frame.midX - activationWidth / 2,
            y: activationBottom,
            width: activationWidth,
            height: screen.frame.maxY - activationBottom + 1
        )
        return surfaceFrame.union(activation)
    }

    private func updateMousePassthrough() {
        // Transparent canvas space must never block the application below it.
        panel.ignoresMouseEvents = !surfaceFrame.contains(NSEvent.mouseLocation)
    }

    private func pointerMoved() {
        guard panel.isVisible else { return }
        let inside = hoverFrame.contains(NSEvent.mouseLocation)
        updateMousePassthrough()
        if inside != pointerInside { hover(inside) }
    }

    private func hover(_ inside: Bool) {
        guard panel.isVisible else { return }
        pointerInside = inside
        pendingHover?.cancel()
        guard !state.isEditingWidgets else { return }
        let delay = inside ? settings.openDelay : settings.closeDelay
        pendingHover = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch { return }
            guard let self, !Task.isCancelled, self.panel.isVisible,
                  !self.state.isEditingWidgets else { return }
            if !inside {
                // A resize may generate an exit event while the pointer is still inside.
                guard !self.hoverFrame.contains(NSEvent.mouseLocation) else { return }
            }
            self.setExpanded(inside)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.expanded = expanded
        if reduceMotion || !settings.animationsEnabled {
            finishTransition()
            return
        }
        guard displayLink == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        let link = panel.displayLink(target: self, selector: #selector(animateFrame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func animateFrame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTime
        lastFrameTime = now
        transition.advance(expanded: state.expanded, elapsed: elapsed, speed: settings.animationSpeed)
        if transition.isSettled(expanded: state.expanded) {
            stopAnimation()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.progress = CGFloat(max(0, min(1, transition.surface.progress)))
            state.contentProgress = CGFloat(max(0, min(1, transition.content.progress)))
        }
        updateMousePassthrough()
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func finishTransition() {
        stopAnimation()
        transition = IslandTransition(expanded: state.expanded)
        state.progress = CGFloat(transition.surface.progress)
        state.contentProgress = CGFloat(transition.content.progress)
        updateMousePassthrough()
    }
}
