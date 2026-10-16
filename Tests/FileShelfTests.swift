import Foundation
@testable import AgentNotch

@MainActor
enum FileShelfTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("shelf persistence and duplicate identity", persistence),
        ("missing shelf files remain removable", missingFile),
        ("malformed shelf entries preserve valid records", malformedRecords),
        ("corrupt shelf archive is preserved before repair", corruptArchive),
        ("unresolvable shelf bookmarks remain visible", invalidBookmark),
        ("dropping unavailable file repairs bookmark in place", renewedDuplicate),
        ("stale shelf bookmarks renew with balanced access", staleBookmarks),
        ("shelf write failures preserve visible records", writeFailure),
        ("shelf accepts only existing local files", invalidDrops)
    ]

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    private static var codec: FileShelfBookmarkCodec {
        FileShelfBookmarkCodec(
            create: { Data($0.absoluteString.utf8) },
            resolve: { data in
                guard let value = String(data: data, encoding: .utf8),
                      let url = URL(string: value), url.isFileURL else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (url, false)
            },
            startAccess: { _ in false }, stopAccess: { _ in }
        )
    }

    private static func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileShelfTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @discardableResult
    private static func file(_ root: URL, _ name: String = "sample.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("original content".utf8).write(to: url)
        return url
    }

    private static func persistence() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let first = try file(root, "a/sample.txt")
            let second = try file(root, "b/sample.txt")
            let alias = root.appendingPathComponent("alias.txt")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
            let store = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(store.add([first, first, alias, second]), "valid files must be accepted")
            try expect(store.items.count == 2, "deduplicate by location; retain distinct same-name files")
            let ids = store.items.map(\.id)
            let loaded = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(loaded.items.map(\.id) == ids, "stable identities survive reload")
            try expect(loaded.items.allSatisfy(\.isAvailable), "loaded paths resolve")
            try expect(loaded.remove(id: ids[0]), "removal succeeds")
            try expect(FileManager.default.fileExists(atPath: first.path), "removal never deletes original")
            try expect(FileShelfStore(storageURL: storage, bookmarkCodec: codec).items.count == 1,
                       "removal persists")
        }
    }

    private static func missingFile() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let original = try file(root)
            let store = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(store.add([original]), "add initial file")
            let id = store.items[0].id
            try FileManager.default.removeItem(at: original)
            let loaded = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(loaded.items.count == 1 && !loaded.items[0].isAvailable,
                       "missing file retains unavailable shelf card")
            loaded.refresh()
            try expect(loaded.items[0].url == nil, "refresh never exposes a missing file to drag sources")
            try expect(loaded.remove(id: id), "missing entry can be removed")
            try expect(FileShelfStore(storageURL: storage, bookmarkCodec: codec).items.isEmpty,
                       "empty shelf persists")
        }
    }

    private static func malformedRecords() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let original = try file(root)
            let store = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(store.add([original]), "add initial file")
            var rootJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [String: Any]
            let records = rootJSON["items"] as! [Any]
            rootJSON["items"] = records + [["name": "broken"], records[0]]
            try JSONSerialization.data(withJSONObject: rootJSON).write(to: storage)
            let loaded = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(loaded.items.count == 1 && loaded.items[0].isAvailable,
                       "skip malformed and duplicate records without hiding valid file")
            try expect(loaded.errorMessage == .someRecordsUnreadable, "corruption retains a translatable cause")
        }
    }

    private static func invalidBookmark() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let original = try file(root)
            let store = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(store.add([original]), "add initial file")
            var failing = codec
            failing.resolve = { _ in throw CocoaError(.fileReadCorruptFile) }
            let loaded = FileShelfStore(storageURL: storage, bookmarkCodec: failing)
            try expect(loaded.items.count == 1 && !loaded.items[0].isAvailable,
                       "bad bookmark remains visible as unavailable")
            try expect(loaded.items[0].name == original.lastPathComponent, "saved display name is retained")
        }
    }

    private static func corruptArchive() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let damaged = Data("incomplete JSON {".utf8)
            try damaged.write(to: storage)
            let store = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(store.errorMessage == .cannotRead, "corrupt archive retains a translatable cause")
            let original = try file(root)
            try expect(store.add([original]), "valid file can repair an unreadable-format shelf")
            let recovery = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("FileShelf-recovery-") }
            try expect(recovery.count == 1, "one recovery snapshot is retained")
            let recovered = try Data(contentsOf: recovery[0])
            try expect(recovered == damaged, "snapshot preserves original bytes")
            try expect(FileShelfStore(storageURL: storage, bookmarkCodec: codec).items.count == 1,
                       "repaired archive persists")
        }
    }

    private static func staleBookmarks() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let original = try file(root)
            let store = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(store.add([original]), "add initial file")
            var starts = 0
            var stops = 0
            var renewals = 0
            let base = codec
            let scoped = FileShelfBookmarkCodec(create: { url in
                renewals += 1
                return try base.create(url)
            }, resolve: { data in
                let result = try base.resolve(data)
                return (result.url, true)
            }, startAccess: { _ in starts += 1; return true },
               stopAccess: { _ in stops += 1 })
            let loaded = FileShelfStore(storageURL: storage, bookmarkCodec: scoped)
            try expect(renewals == 1 && starts == stops, "refresh renews stale bookmark while scope is open")
            loaded.refresh()
            try expect(renewals == 2 && starts == 2 && stops == 2,
                       "repeated refresh balances each resource scope")
        }
    }

    private static func renewedDuplicate() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let original = try file(root)
            let initial = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(initial.add([original]), "add initial file")
            let id = initial.items[0].id
            let oldBookmark = try codec.create(original)
            let base = codec
            let repairedCodec = FileShelfBookmarkCodec(create: { url in
                Data("renewed:".utf8) + (try base.create(url))
            }, resolve: { data in
                guard data != oldBookmark else { throw CocoaError(.fileReadNoPermission) }
                return try base.resolve(Data(data.dropFirst("renewed:".utf8.count)))
            }, startAccess: { _ in false }, stopAccess: { _ in })
            let loaded = FileShelfStore(storageURL: storage, bookmarkCodec: repairedCodec)
            try expect(loaded.items.count == 1 && !loaded.items[0].isAvailable,
                       "old bookmark has lost permission")
            try expect(loaded.add([original]), "new drop grants fresh access")
            try expect(loaded.items.count == 1 && loaded.items[0].id == id && loaded.items[0].isAvailable,
                       "repair updates the original card instead of duplicating it")
            let reloaded = FileShelfStore(storageURL: storage, bookmarkCodec: repairedCodec)
            try expect(reloaded.items.count == 1 && reloaded.items[0].id == id && reloaded.items[0].isAvailable,
                       "renewed permission and stable identity survive restart")
        }
    }

    private static func writeFailure() throws {
        try withDirectory { root in
            let storage = root.appendingPathComponent("shelf.json")
            let first = try file(root)
            let second = try file(root, "second.txt")
            let store = FileShelfStore(storageURL: storage, bookmarkCodec: codec)
            try expect(store.add([first]), "add initial file")
            let id = store.items[0].id
            try FileManager.default.removeItem(at: storage)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try expect(!store.remove(id: id), "failed durable removal must report failure")
            try expect(store.items.map(\.id) == [id], "failed removal retains existing card")
            try expect(!store.add([second]), "failed save rejects new file")
            try expect(store.items.map(\.id) == [id] && store.errorMessage == .cannotSave,
                       "failed add retains previous state and surfaces error")
            try expect(FileManager.default.fileExists(atPath: first.path), "original is untouched")
        }
    }

    private static func invalidDrops() throws {
        try withDirectory { root in
            let store = FileShelfStore(storageURL: root.appendingPathComponent("shelf.json"), bookmarkCodec: codec)
            try expect(!store.add([URL(string: "https://example.com")!, root.appendingPathComponent("missing")]),
                       "reject remote and nonexistent URLs")
            try expect(store.items.isEmpty, "invalid drop does not create cards")
            try expect(store.errorMessage == .cannotAccess("missing"),
                       "unavailable file error retains its filename for later translation")
            let folder = root.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try expect(store.add([folder]), "local folders are accepted")
        }
    }
}
