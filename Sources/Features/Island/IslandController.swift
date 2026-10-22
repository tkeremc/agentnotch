import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class IslandController: NSObject {
    private let state = IslandState()
    private let shelf = FileShelfStore()
    private let media = NowPlayingStore()
    private let codex: CodexStore
    private let claude: ClaudeStore
    private let compactMedia = CompactMediaVisibility()
    private var mediaMonitoringEnabled = false
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
    private var settingsPresented = false
    private var transition = IslandTransition()
    private var pageMotion = IslandMotion()
    private var dragHintMotion = IslandMotion()
    private var mediaMotion = IslandMotion()
    private var codexMotion = IslandMotion()
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var dragTimer: Timer?
    private var dragPasteboardBaseline = 0
    private var releasePending: Task<Void, Never>?

    init(settings: NotchSettings, codex: CodexStore, claude: ClaudeStore,
         openCodexSettings: (() -> Void)? = nil, openClaudeSettings: (() -> Void)? = nil,
         openSettings: @escaping () -> Void) {
        self.settings = settings
        self.codex = codex
        self.claude = claude
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        state.openSettings = openSettings
        state.openCodexSettings = openCodexSettings ?? openSettings
        state.openClaudeSettings = openClaudeSettings ?? openSettings
        state.openCodex = { [weak self] in
            guard let self else { return }
            self.state.selectPage(.home)
            self.setExpanded(true)
        }
        state.openMedia = { [weak self] in
            guard let self else { return }
            self.state.selectPage(.home)
            self.setExpanded(true)
        }
        state.editingChanged = { [weak self] in self?.editingChanged() }
        state.pageChanged = { [weak self] in
            guard let self else { return }
            if self.state.page == .files { self.shelf.refresh() }
            self.animatePageChange()
            self.pointerMoved()
        }
        state.dropTargetChanged = { [weak self] targeted in
            guard let self else { return }
            guard self.state.isDropTargeted != targeted else { return }
            if targeted {
                self.state.beginIncomingDrag()
                self.pendingHover?.cancel()
                self.setExpanded(true)
            }
            self.state.isDropTargeted = targeted
        }
        state.filesDropped = { [weak self] urls in
            guard let self else { return false }
            let accepted = self.shelf.add(urls)
            self.finishIncomingDrag(accepted: accepted)
            return accepted
        }
        state.outgoingChanged = { [weak self] dragging in
            guard let self else { return }
            self.state.isOutgoingDrag = dragging
            if dragging { self.setFileDragAvailable(false) }
            self.pendingHover?.cancel()
            if dragging { self.setExpanded(true) }
            else { self.hover(self.hoverFrame.contains(NSEvent.mouseLocation)) }
        }
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
        let view = HoverHostingView(rootView: IslandView(state: state, settings: settings, shelf: shelf, media: media, codex: codex, claude: claude))
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
            self?.updateMediaMonitoring(widgets: widgets)
            self?.updateCodexMonitoring(widgets: widgets)
        }.store(in: &subscriptions)
        media.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.compactMedia.update(isPlaying: self.mediaMonitoringEnabled ? snapshot?.isPlaying : nil)
        }.store(in: &subscriptions)
        compactMedia.$isVisible.removeDuplicates().sink { [weak self] visible in
            self?.setMediaAvailable(visible)
        }.store(in: &subscriptions)
        codex.$compactAgents.combineLatest(claude.$compactAgents).sink { [weak self] codexAgents, claudeAgents in
            guard let self else { return }
            let agents = codexAgents.map { value in
                CodexCompactAgent(id: "codex:" + value.id, name: value.name,
                                  indicator: value.indicator, iconName: value.iconName, role: value.role)
            } + claudeAgents.map { value in
                CodexCompactAgent(id: "claude:" + value.id, name: value.name,
                                  indicator: value.indicator, iconName: "ClaudeMark", role: value.role)
            }
            let previousCount = self.state.codexCompactAgents.count
            self.state.codexCompactAgents = agents
            self.state.codexIndicator = agents.first?.indicator ?? .none
            if agents.count > previousCount { self.updateDrawerLayout(widgets: self.settings.widgets) }
            self.setCodexAlertAvailable(!agents.isEmpty)
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
        state.restorePageAfterCollapse()
        state.hasFileDrag = false
        state.dragHintProgress = 0
        dragHintMotion = IslandMotion()
        pageMotion = IslandMotion(progress: pageTarget)
        state.pageProgress = CGFloat(pageTarget)
        pointerInside = false
        positionOnScreen()
        startMouseMonitoring()
        panel.orderFrontRegardless()
        updateMediaMonitoring(widgets: settings.widgets)
        updateCodexMonitoring(widgets: settings.widgets)
        pointerMoved()
    }

    func hide() {
        panel.orderOut(nil)
        mediaMonitoringEnabled = false
        compactMedia.update(isPlaying: nil)
        media.stop()
        codex.stop(releaseCaches: !settings.widgets.contains(.codex))
        claude.stop(releaseCaches: !settings.widgets.contains(.claude))
        state.hasCodexAlert = false
        state.codexAlertProgress = 0
        state.codexSlotsProgress = 0
        codexMotion = IslandMotion()
        state.hasMedia = false
        state.mediaProgress = 0
        mediaMotion = IslandMotion()
        setFileDragAvailable(false)
        releasePending?.cancel()
        state.endIncomingDrag()
        state.isEditingWidgets = false
        pendingHover?.cancel()
        stopAnimation()
        state.expanded = false
        state.progress = 0
        state.contentProgress = 0
        state.restorePageAfterCollapse()
        transition = IslandTransition()
        pointerInside = false
        stopMouseMonitoring()
    }

    /// The status-level panel must never cover settings or its consent UI.
    /// Keep it collapsed until settings closes or is minimized.
    func setSettingsPresented(_ presented: Bool) {
        settingsPresented = presented
        pendingHover?.cancel()
        if presented {
            dragTimer?.invalidate()
            dragTimer = nil
            releasePending?.cancel()
            state.isEditingWidgets = false
            state.endIncomingDrag()
            setFileDragAvailable(false)
            state.expanded = false
            finishTransition()
            pointerInside = false
        } else {
            pointerMoved()
        }
    }

    private func startMouseMonitoring() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.mouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.mouseEvent(event)
            return event
        }
    }

    private func stopMouseMonitoring() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func positionOnScreen() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let notchHeight = screen.safeAreaInsets.top
        state.topBand = (notchHeight > 0 ? notchHeight : 32) + 2
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
        state.shelfHeight = min(240, maximumHeight)
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
        NSRect(x: panel.frame.midX - state.surfaceWidth / 2 + state.surfaceOffsetX,
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
        panel.ignoresMouseEvents = settingsPresented || !surfaceFrame.contains(NSEvent.mouseLocation)
    }

    private func pointerMoved() {
        guard panel.isVisible, !settingsPresented else { return }
        let inside = hoverFrame.contains(NSEvent.mouseLocation)
        updateMousePassthrough()
        if inside != pointerInside { hover(inside) }
    }

    private func mouseEvent(_ event: NSEvent) {
        guard !settingsPresented else { return }
        if event.type == .leftMouseDown {
            dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
            releasePending?.cancel()
            setFileDragAvailable(false)
            startDragTimer()
        } else if event.type == .leftMouseDragged {
            startDragTimer()
            inspectDrag()
        }
        pointerMoved()
    }

    private func startDragTimer() {
        guard dragTimer == nil else { return }
        // AppKit can enter a native tracking loop that suppresses mouse monitors.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.inspectDrag() }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func inspectDrag() {
        guard panel.isVisible, !settingsPresented else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            setFileDragAvailable(false)
            dragTimer?.invalidate()
            dragTimer = nil
            // Let the destination finish its drop callback before restoring a tab.
            releasePending?.cancel()
            releasePending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.finishIncomingDrag()
                self.dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
            }
            return
        }
        guard !state.isOutgoingDrag else {
            setFileDragAvailable(false)
            return
        }
        let pasteboard = NSPasteboard(name: .drag)
        // The global hint only needs advertised types. Reading file URL payloads
        // before a drop repeatedly requests sandbox access from other apps.
        guard pasteboard.changeCount != dragPasteboardBaseline,
              !FileShelfDragTypes.isShelfDrag(pasteboard),
              pasteboard.types?.contains(.fileURL) == true else {
            setFileDragAvailable(false)
            if state.isIncomingDrag { finishIncomingDrag() }
            return
        }
        setFileDragAvailable(true)
        let nearby = hoverFrame.insetBy(dx: -48, dy: -48).contains(NSEvent.mouseLocation)
        if nearby {
            state.beginIncomingDrag()
            pendingHover?.cancel()
            setExpanded(true)
        } else if state.isIncomingDrag && !state.isDropTargeted {
            finishIncomingDrag()
        }
        pointerMoved()
    }

    private func finishIncomingDrag(accepted: Bool = false) {
        guard state.isIncomingDrag || accepted else { return }
        state.endIncomingDrag(accepted: accepted)
        hover(hoverFrame.contains(NSEvent.mouseLocation))
    }

    private func hover(_ inside: Bool) {
        guard panel.isVisible, !settingsPresented else { return }
        pointerInside = inside
        pendingHover?.cancel()
        guard !state.holdsOpen else { return }
        let delay = inside ? settings.openDelay : settings.closeDelay
        pendingHover = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch { return }
            guard let self, !Task.isCancelled, self.panel.isVisible,
                  !self.state.holdsOpen else { return }
            if !inside {
                // A resize may generate an exit event while the pointer is still inside.
                guard !self.hoverFrame.contains(NSEvent.mouseLocation) else { return }
            }
            self.setExpanded(inside)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard !expanded || !settingsPresented else { return }
        guard state.expanded != expanded else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.expanded = expanded
        if reduceMotion || !settings.animationsEnabled {
            finishTransition()
            return
        }
        startAnimation()
    }

    private var pageTarget: Double { state.page == .files ? 1 : 0 }
    private var dragHintTarget: Double { state.showsDragHint ? 1 : 0 }
    private var mediaTarget: Double { state.hasMedia ? 1 : 0 }
    private var codexTarget: Double {
        state.hasCodexAlert ? Double(max(1, state.codexCompactAgents.count)) : 0
    }

    private func updateCodexMonitoring(widgets: [WidgetKind]) {
        if panel.isVisible && widgets.contains(.codex) { codex.start() }
        else { codex.stop(releaseCaches: !widgets.contains(.codex)) }
        if panel.isVisible && widgets.contains(.claude) { claude.start() }
        else { claude.stop(releaseCaches: !widgets.contains(.claude)) }
    }

    private func setCodexAlertAvailable(_ available: Bool) {
        let available = available && panel.isVisible && (settings.widgets.contains(.codex) || settings.widgets.contains(.claude))
        let changed = state.hasCodexAlert != available
        state.hasCodexAlert = available
        guard changed || codexMotion.progress != codexTarget || codexMotion.velocity != 0 else { return }
        guard panel.isVisible, settings.animationsEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            codexMotion = IslandMotion(progress: codexTarget)
            state.codexAlertProgress = CGFloat(min(1, codexTarget))
            state.codexSlotsProgress = CGFloat(codexTarget)
            updateMousePassthrough()
            return
        }
        startAnimation()
    }

    private func updateMediaMonitoring(widgets: [WidgetKind]) {
        mediaMonitoringEnabled = panel.isVisible && widgets.contains(.media)
        if mediaMonitoringEnabled {
            media.start()
            compactMedia.update(isPlaying: media.snapshot?.isPlaying)
        } else {
            compactMedia.update(isPlaying: nil)
            media.stop()
        }
    }

    private func setMediaAvailable(_ available: Bool) {
        guard state.hasMedia != available else { return }
        state.hasMedia = available
        guard panel.isVisible, settings.animationsEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            mediaMotion = IslandMotion(progress: mediaTarget)
            state.mediaProgress = CGFloat(mediaTarget)
            updateMousePassthrough()
            return
        }
        startAnimation()
    }

    private func setFileDragAvailable(_ available: Bool) {
        guard state.hasFileDrag != available else { return }
        state.hasFileDrag = available
        guard panel.isVisible, settings.animationsEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dragHintMotion = IslandMotion(progress: dragHintTarget)
            state.dragHintProgress = CGFloat(dragHintTarget)
            return
        }
        startAnimation()
    }

    private func animatePageChange() {
        guard panel.isVisible, state.progress > 0, settings.animationsEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            pageMotion = IslandMotion(progress: pageTarget)
            state.pageProgress = CGFloat(pageTarget)
            return
        }
        // Retarget the existing spring so rapid tab changes remain continuous.
        startAnimation()
    }

    private func startAnimation() {
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
        pageMotion.advance(toward: pageTarget, elapsed: elapsed * settings.animationSpeed, frequency: 26)
        dragHintMotion.advance(toward: dragHintTarget, elapsed: elapsed * settings.animationSpeed, frequency: 40)
        mediaMotion.advance(toward: mediaTarget, elapsed: elapsed * settings.animationSpeed, frequency: 34)
        codexMotion.advance(toward: codexTarget, elapsed: elapsed * settings.animationSpeed, frequency: 34)
        if transition.isSettled(expanded: state.expanded),
           pageMotion.progress == pageTarget, pageMotion.velocity == 0,
           dragHintMotion.progress == dragHintTarget, dragHintMotion.velocity == 0,
           mediaMotion.progress == mediaTarget, mediaMotion.velocity == 0,
           codexMotion.progress == codexTarget, codexMotion.velocity == 0 {
            stopAnimation()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.progress = CGFloat(max(0, min(1, transition.surface.progress)))
            state.contentProgress = CGFloat(max(0, min(1, transition.content.progress)))
            state.pageProgress = CGFloat(max(0, min(1, pageMotion.progress)))
            state.dragHintProgress = CGFloat(max(0, min(1, dragHintMotion.progress)))
            state.mediaProgress = CGFloat(max(0, min(1, mediaMotion.progress)))
            state.codexAlertProgress = CGFloat(max(0, min(1, codexMotion.progress)))
            state.codexSlotsProgress = CGFloat(max(0, codexMotion.progress))
            state.restorePageAfterCollapse()
        }
        pointerMoved()
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func finishTransition() {
        stopAnimation()
        transition = IslandTransition(expanded: state.expanded)
        pageMotion = IslandMotion(progress: pageTarget)
        dragHintMotion = IslandMotion(progress: dragHintTarget)
        mediaMotion = IslandMotion(progress: mediaTarget)
        codexMotion = IslandMotion(progress: codexTarget)
        state.progress = CGFloat(transition.surface.progress)
        state.contentProgress = CGFloat(transition.content.progress)
        state.pageProgress = CGFloat(pageTarget)
        state.dragHintProgress = CGFloat(dragHintTarget)
        state.mediaProgress = CGFloat(mediaTarget)
        state.codexAlertProgress = CGFloat(min(1, codexTarget))
        state.codexSlotsProgress = CGFloat(codexTarget)
        state.restorePageAfterCollapse()
        updateMousePassthrough()
    }
}
