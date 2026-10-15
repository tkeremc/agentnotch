import AppKit
import Combine
import QuartzCore
import SwiftUI

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
