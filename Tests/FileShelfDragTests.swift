import AppKit
import SwiftUI
@testable import AgentNotch

@MainActor
enum FileShelfDragTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("native file destination delivers multiple native URL objects", validDrop),
        ("native file destination clears hover on exit and cancellation", exitAndCancel),
        ("native file destination rejects unsupported and self-originated drags", unsupportedDrags),
        ("native file destination requires copy throughout the drag", sourceOperations),
        ("native file destination propagates failed storage and clears hover", failedDrop),
        ("native shelf writer preserves NSURL flavors and self marker", writerRoundtrip),
        ("hidden shelf destination cannot intercept home page drags", disabledDestination)
    ]

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    private static let sample = URL(fileURLWithPath: "/tmp/agentnotch bridge/örnek.txt")

    private static func withPasteboard(_ body: (NSPasteboard) throws -> Void) throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private static func validDrop() throws {
        try withPasteboard { pasteboard in
            let urls = [sample, URL(fileURLWithPath: "/tmp/another file.pdf")]
            try expect(pasteboard.writeObjects(urls.map { $0 as NSURL }), "write native URL objects")
            let info = DragInfo(pasteboard)
            var targets: [Bool] = []
            var received: [[URL]] = []
            let view = FileShelfDestinationView(content: EmptyView(), onTargeted: { targets.append($0) },
                                                onDrop: { received.append($0); return true })
            try expect(view.registeredDraggedTypes.contains(.fileURL), "native ancestor registers file drops")
            try expect(view.draggingEntered(info) == .copy, "valid incoming files offer copy")
            try expect(view.draggingUpdated(info) == .copy && targets == [true], "updates keep one highlight")
            try expect(view.prepareForDragOperation(info), "valid native drop prepares")
            try expect(view.performDragOperation(info), "native URL object reader delivers the drop")
            view.concludeDragOperation(info)
            view.draggingEnded(info)
            try expect(received == [urls], "all URLs arrive in original order with names intact")
            try expect(targets == [true, false], "successful drop clears highlight exactly once")
        }
    }

    private static func exitAndCancel() throws {
        try withPasteboard { pasteboard in
            pasteboard.writeObjects([sample as NSURL])
            let info = DragInfo(pasteboard)
            var targets: [Bool] = []
            var drops = 0
            let view = FileShelfDestinationView(content: EmptyView(), onTargeted: { targets.append($0) },
                                                onDrop: { _ in drops += 1; return true })
            _ = view.draggingEntered(info)
            view.draggingExited(info)
            _ = view.draggingEntered(info)
            view.draggingEnded(info)
            try expect(targets == [true, false, true, false], "exit and cancel both clear active hover")
            try expect(drops == 0, "aborted native sessions never commit files")
        }
    }

    private static func unsupportedDrags() throws {
        let cases: [[(NSPasteboard.PasteboardType, String)]] = [
            [(.string, "plain text")],
            [(.URL, "https://example.com/file.txt")],
            [(.fileURL, "https://example.com/file.txt")],
            [(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), sample.absoluteString)],
            [(.fileURL, sample.absoluteString), (FileShelfDragTypes.sourceMarker, "self")]
        ]
        for flavors in cases {
            try withPasteboard { pasteboard in
                let item = NSPasteboardItem()
                for (type, value) in flavors { item.setString(value, forType: type) }
                pasteboard.writeObjects([item])
                let info = DragInfo(pasteboard)
                var highlighted = false
                var calledDrop = false
                let view = FileShelfDestinationView(content: EmptyView(), onTargeted: { highlighted = $0 },
                                                    onDrop: { _ in calledDrop = true; return true })
                try expect(view.draggingEntered(info).isEmpty, "unsupported flavor is rejected at entry")
                try expect(!view.prepareForDragOperation(info), "unsupported flavor cannot prepare")
                try expect(!view.performDragOperation(info), "unsupported flavor cannot commit")
                try expect(!highlighted && !calledDrop, "rejected drag does not highlight or invoke storage")
            }
        }
    }

    private static func sourceOperations() throws {
        try withPasteboard { pasteboard in
            pasteboard.writeObjects([sample as NSURL])
            let info = DragInfo(pasteboard)
            info.draggingSourceOperationMask = .move
            var targets: [Bool] = []
            let view = FileShelfDestinationView(content: EmptyView(), onTargeted: { targets.append($0) },
                                                onDrop: { _ in true })
            try expect(view.draggingEntered(info).isEmpty, "move-only drags cannot enter shelf")
            info.draggingSourceOperationMask = [.copy, .move]
            try expect(view.draggingUpdated(info) == .copy, "mixed source mask negotiates copy only")
            info.draggingSourceOperationMask = .move
            try expect(view.draggingUpdated(info).isEmpty, "changing source mask revokes acceptance")
            try expect(!view.prepareForDragOperation(info), "copy is revalidated at prepare")
            try expect(targets == [true, false], "revoked copy support removes highlight")
        }
    }

    private static func failedDrop() throws {
        try withPasteboard { pasteboard in
            pasteboard.writeObjects([sample as NSURL])
            let info = DragInfo(pasteboard)
            var targets: [Bool] = []
            var drops = 0
            let view = FileShelfDestinationView(content: EmptyView(), onTargeted: { targets.append($0) },
                                                onDrop: { _ in drops += 1; return false })
            _ = view.draggingEntered(info)
            try expect(!view.performDragOperation(info), "storage failure propagates to drag manager")
            try expect(drops == 1 && targets == [true, false], "failed commit runs once and clears hover")
        }
    }

    private static func disabledDestination() throws {
        try withPasteboard { pasteboard in
            pasteboard.writeObjects([sample as NSURL])
            let info = DragInfo(pasteboard)
            var targets: [Bool] = []
            var committed = false
            let view = FileShelfDestinationView(content: EmptyView(), onTargeted: { targets.append($0) },
                                                onDrop: { _ in committed = true; return true })
            _ = view.draggingEntered(info)
            view.isEnabled = false
            try expect(view.registeredDraggedTypes.isEmpty && targets == [true, false],
                       "fading out unregisters native destination and clears its highlight")
            try expect(view.draggingUpdated(info).isEmpty && !view.performDragOperation(info) && !committed,
                       "a hidden file shelf cannot accept drops intended for home")
            view.isEnabled = true
            try expect(view.draggingEntered(info) == .copy,
                       "switching back to depot restores native acceptance")
        }
    }

    private static func writerRoundtrip() throws {
        try withPasteboard { pasteboard in
            let native = sample as NSURL
            let writer = FileShelfPasteboardWriter(url: sample, marker: "test-source")
            let nativeTypes = native.writableTypes(for: pasteboard)
            let actualTypes = writer.writableTypes(for: pasteboard)
            try expect(nativeTypes.allSatisfy(actualTypes.contains), "all native URL flavors are preserved")
            for type in nativeTypes {
                let expected = native.pasteboardPropertyList(forType: type) as? NSObject
                let actual = writer.pasteboardPropertyList(forType: type) as? NSObject
                try expect(expected == actual, "native URL property list remains unchanged for \(type)")
                let options = (native as NSPasteboardWriting)
                    .writingOptions?(forType: type, pasteboard: pasteboard) ?? []
                try expect(writer.writingOptions(forType: type, pasteboard: pasteboard) == options,
                           "native writing options remain unchanged")
            }
            try expect(pasteboard.writeObjects([writer]), "native writer can populate a real pasteboard")
            try expect(pasteboard.string(forType: FileShelfDragTypes.sourceMarker) == "test-source",
                       "own source marker survives pasteboard write")
            try expect(FileShelfDragTypes.isShelfDrag(pasteboard), "destination recognizes own source")
            let read = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]
            try expect(read == [sample], "NSURL reader reconstructs the original file URL")
        }
    }
}

/// Only supplies the drag manager's inputs; production destination methods do
/// all validation, negotiation and pasteboard reading in the tests above.
@MainActor
private final class DragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
