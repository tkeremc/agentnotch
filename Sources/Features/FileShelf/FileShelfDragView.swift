import AppKit
import SwiftUI

enum FileShelfDragTypes {
    static let sourceMarker = NSPasteboard.PasteboardType("com.local.NotchLab.file-shelf-source")

    static func isShelfDrag(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(sourceMarker) == true
    }

    /// Reading the concrete file URL flavor deliberately excludes file promises.
    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        var urls: [URL] = []
        for item in items {
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value), url.isFileURL else { return [] }
            urls.append(url)
        }
        return urls
    }
}

/// A registered native ancestor receives drops without covering SwiftUI buttons
/// or the scroll view with a hit-testing overlay.
struct FileShelfDropDestination<Content: View>: NSViewRepresentable {
    let isEnabled: Bool
    let onTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Bool
    let content: Content

    init(isEnabled: Bool = true, onTargeted: @escaping (Bool) -> Void,
         onDrop: @escaping ([URL]) -> Bool,
         @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.onTargeted = onTargeted
        self.onDrop = onDrop
        self.content = content()
    }

    func makeNSView(context: Context) -> FileShelfDestinationView<Content> {
        let view = FileShelfDestinationView(content: content, onTargeted: onTargeted, onDrop: onDrop)
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: FileShelfDestinationView<Content>, context: Context) {
        nsView.hostingView.rootView = content
        nsView.onTargeted = onTargeted
        nsView.onDrop = onDrop
        nsView.isEnabled = isEnabled
    }
}

@MainActor
final class FileShelfDestinationView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    var onTargeted: (Bool) -> Void
    var onDrop: ([URL]) -> Bool
    private var targeted = false
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled {
                unregisterDraggedTypes()
                setTargeted(false)
            } else if !oldValue {
                registerForDraggedTypes([.fileURL])
            }
        }
    }

    init(content: Content, onTargeted: @escaping (Bool) -> Void,
         onDrop: @escaping ([URL]) -> Bool) {
        hostingView = NSHostingView(rootView: content)
        self.onTargeted = onTargeted
        self.onDrop = onDrop
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accepts(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender) else {
            setTargeted(false)
            return false
        }
        // AppKit's NSURL reader carries sandbox access granted by the source;
        // constructing fresh URLs from strings would discard that information.
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            setTargeted(false)
            return false
        }
        let handled = onDrop(urls)
        setTargeted(false)
        return handled
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        isEnabled && sender.draggingSourceOperationMask.contains(.copy)
            && !FileShelfDragTypes.isShelfDrag(sender.draggingPasteboard)
            && !FileShelfDragTypes.fileURLs(in: sender.draggingPasteboard).isEmpty
    }

    private func updateTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = accepts(sender)
        setTargeted(accepted)
        return accepted ? .copy : []
    }

    private func setTargeted(_ value: Bool) {
        guard targeted != value else { return }
        targeted = value
        onTargeted(value)
    }
}

/// Keep NSURL's native pasteboard representations, including sandbox transfer
/// information, and add only the marker used to reject self-originated drops.
final class FileShelfPasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: NSURL
    private let marker: String

    init(url: URL, marker: String) {
        self.url = url as NSURL
        self.marker = marker
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        url.writableTypes(for: pasteboard) + [FileShelfDragTypes.sourceMarker]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == FileShelfDragTypes.sourceMarker ? marker : url.pasteboardPropertyList(forType: type)
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        guard type != FileShelfDragTypes.sourceMarker else { return [] }
        return (url as NSPasteboardWriting).writingOptions?(forType: type, pasteboard: pasteboard) ?? []
    }
}

/// Place this over the draggable portion of a card, leaving its buttons outside.
struct FileShelfDragSource: NSViewRepresentable {
    let url: URL?
    var icon: NSImage? = nil
    let onBegan: () -> Void
    let onEnded: (NSDragOperation) -> Void

    func makeNSView(context: Context) -> FileShelfSourceView {
        let view = FileShelfSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FileShelfSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FileShelfSourceView) {
        view.url = url
        view.icon = icon
        view.onBegan = onBegan
        view.onEnded = onEnded
    }
}

@MainActor
final class FileShelfSourceView: NSView, NSDraggingSource {
    var url: URL?
    var icon: NSImage?
    var onBegan: (() -> Void)?
    var onEnded: ((NSDragOperation) -> Void)?
    private var mouseDownPoint: NSPoint?
    private var activeURL: URL?
    private var securityScopeStarted = false
    private var completion: ((NSDragOperation) -> Void)?
    private let sessionID = UUID()

    // The expanded SwiftUI subtree may disappear while AppKit owns a drag.
    // Retain its source, scoped URL and original completion until the session ends.
    private static var activeSources: [UUID: FileShelfSourceView] = [:]

    override func hitTest(_ point: NSPoint) -> NSView? {
        url == nil ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeURL == nil, let origin = mouseDownPoint, let url else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        guard dx * dx + dy * dy >= 16 else { return }
        mouseDownPoint = nil

        activeURL = url
        securityScopeStarted = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            if securityScopeStarted { url.stopAccessingSecurityScopedResource() }
            securityScopeStarted = false
            activeURL = nil
            onEnded?([])
            return
        }

        let writer = FileShelfPasteboardWriter(url: url, marker: sessionID.uuidString)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let preview = icon ?? NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                              contents: preview)

        completion = onEnded
        Self.activeSources[sessionID] = self
        onBegan?()
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let callback = completion
        completion = nil
        callback?(operation)
        if securityScopeStarted { activeURL?.stopAccessingSecurityScopedResource() }
        securityScopeStarted = false
        activeURL = nil
        Self.activeSources[sessionID] = nil
    }
}
