import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var progress: CGFloat = 0
    @Published var contentProgress: CGFloat = 0
    @Published var topBand: CGFloat = 32
    @Published var collapsedBottomInset: CGFloat = 0
    @Published var collapsedWidth: CGFloat = 200
    @Published var expandedWidth: CGFloat = 420
    @Published var pinned = false

    var pinChanged: (() -> Void)?
    var surfaceWidth: CGFloat { collapsedWidth + (expandedWidth - collapsedWidth) * progress }
    var surfaceHeight: CGFloat { topBand + 164 * progress - collapsedBottomInset * (1 - progress) }
    var canvasSize: NSSize { NSSize(width: expandedWidth + 24, height: topBand + 176) }
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

// Geometry finishes before content appears. Closing reverses that order;
// both channels share one display link and remain continuous on reversal.
struct IslandTransition {
    var surface = IslandMotion()
    var content = IslandMotion()

    init(expanded: Bool = false) {
        surface = IslandMotion(progress: expanded ? 1 : 0)
        content = IslandMotion(progress: expanded ? 1 : 0)
    }

    mutating func advance(expanded: Bool, elapsed: Double) {
        if expanded {
            surface.advance(toward: 1, elapsed: elapsed, frequency: 22)
            content.advance(toward: surface.progress == 1 ? 1 : 0,
                            elapsed: elapsed, frequency: 30)
        } else {
            content.advance(toward: 0, elapsed: elapsed, frequency: 38)
            if content.progress == 0 {
                surface.advance(toward: 0, elapsed: elapsed, frequency: 24)
            }
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

    override init() {
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
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
        let view = HoverHostingView(rootView: IslandView(state: state))
        // The controller owns the panel's size. SwiftUI's automatic window
        // min/max constraints otherwise feed animated layout back into AppKit.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.hoverChanged = { [weak self] inside in self?.hover(inside) }
        // A hosting view used directly as window content also participates in
        // SwiftUI's animated window sizing. A plain AppKit container keeps that
        // mechanism separate from the controller's explicit frame animation.
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        view.frame = container.bounds
        container.addSubview(view)
        panel.contentView = container
        state.pinChanged = { [weak self] in
            guard let self, !self.state.pinned, !self.pointerInside else { return }
            self.hover(false)
        }
        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            self?.pointerMoved()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.pointerMoved()
            return event
        }
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
        state.pinned = false
        pointerInside = false
        positionOnScreen()
        panel.orderFrontRegardless()
        pointerMoved()
    }

    func hide() {
        pendingHover?.cancel()
        stopAnimation()
        state.pinned = false
        state.expanded = false
        panel.orderOut(nil)
    }

    private func positionOnScreen() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let notchHeight = screen.safeAreaInsets.top
        state.topBand = notchHeight > 0 ? notchHeight : 10
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
        state.expandedWidth = min(max(420, state.collapsedWidth), screen.frame.width - 56)
        let size = state.canvasSize
        // The native window never resizes during hover. Only the black surface
        // inside this transparent canvas changes, so it cannot clip the spring.
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        ), display: true)
        updateMousePassthrough()
    }

    private var surfaceFrame: NSRect {
        NSRect(x: panel.frame.midX - state.surfaceWidth / 2,
               y: panel.frame.maxY - state.surfaceHeight,
               width: state.surfaceWidth, height: state.surfaceHeight)
    }

    private func updateMousePassthrough() {
        // Transparent canvas space must never block the application below it.
        panel.ignoresMouseEvents = !surfaceFrame.contains(NSEvent.mouseLocation)
    }

    private func pointerMoved() {
        guard panel.isVisible else { return }
        let inside = surfaceFrame.contains(NSEvent.mouseLocation)
        updateMousePassthrough()
        if inside != pointerInside { hover(inside) }
    }

    private func hover(_ inside: Bool) {
        pointerInside = inside
        pendingHover?.cancel()
        pendingHover = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(inside ? 120 : 320))
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            if !inside {
                guard !self.state.pinned else { return }
                // A resize may generate an exit event while the pointer is still inside.
                guard !self.surfaceFrame.contains(NSEvent.mouseLocation) else { return }
            }
            self.setExpanded(inside)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.expanded = expanded
        if reduceMotion {
            stopAnimation()
            transition = IslandTransition(expanded: expanded)
            state.progress = CGFloat(transition.surface.progress)
            state.contentProgress = CGFloat(transition.content.progress)
            updateMousePassthrough()
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
        transition.advance(expanded: state.expanded, elapsed: elapsed)
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
}
