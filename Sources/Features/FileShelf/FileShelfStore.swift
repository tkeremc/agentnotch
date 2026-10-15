import Combine
import Foundation

struct FileShelfItem: Identifiable {
    let id: UUID
    let name: String
    let url: URL?

    var isAvailable: Bool { url != nil }
}

/// The codec keeps bookmark handling injectable without weakening sandbox access
/// in the shipping application.
struct FileShelfBookmarkCodec {
    var create: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, isStale: Bool)
    var startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }

    static let securityScoped = FileShelfBookmarkCodec(
        create: { try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                      includingResourceValuesForKeys: nil, relativeTo: nil) },
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        }
    )
}

@MainActor
final class FileShelfStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem] = []
    @Published private(set) var errorMessage: String?

    private struct Record: Codable, Equatable {
        let id: UUID
        var name: String
        var bookmark: Data
        var originalPath: String?
    }

    private struct Archive: Codable {
        let version: Int
        let items: [Record]
    }

    private let storageURL: URL
    private let bookmarkCodec: FileShelfBookmarkCodec
    private var records: [Record] = []
    private var recoveryData: Data?
    private var archiveCouldNotBeRead = false

    init(storageURL: URL? = nil, bookmarkCodec: FileShelfBookmarkCodec = .securityScoped) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                  in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("FileShelf.json")
        self.bookmarkCodec = bookmarkCodec
        load()
        refresh()
    }

    /// Dropping an existing file renews its permission while preserving its card ID.
    @discardableResult
    func add(_ urls: [URL]) -> Bool {
        errorMessage = nil
        var next = records
        var existingIndexes: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            if let path = record.originalPath { existingIndexes[path] = index }
            if let url = items.first(where: { $0.id == record.id })?.url {
                existingIndexes[Self.identity(url)] = index
            }
        }
        var accepted = false
        for url in urls where url.isFileURL {
            let accessed = bookmarkCodec.startAccess(url)
            defer { if accessed { bookmarkCodec.stopAccess(url) } }
            guard FileManager.default.fileExists(atPath: url.path),
                  FileManager.default.isReadableFile(atPath: url.path) else {
                errorMessage = "Dosyaya erişilemiyor: \(url.lastPathComponent)"
                continue
            }
            let identity = Self.identity(url)
            do {
                let bookmark = try bookmarkCodec.create(url)
                if let index = existingIndexes[identity] {
                    next[index] = Record(id: next[index].id, name: url.lastPathComponent,
                                         bookmark: bookmark, originalPath: identity)
                } else {
                    existingIndexes[identity] = next.count
                    next.append(Record(id: UUID(), name: url.lastPathComponent,
                                       bookmark: bookmark, originalPath: identity))
                }
                accepted = true
            } catch {
                errorMessage = "Dosya depoya eklenemedi: \(url.lastPathComponent)"
            }
        }
        guard accepted else { return false }
        if next != records {
            guard save(next) else { return false }
            records = next
        }
        refresh()
        return true
    }

    /// Persist before publishing removal; a failed save must leave the card visible.
    @discardableResult
    func remove(id: UUID) -> Bool {
        let next = records.filter { $0.id != id }
        guard next.count != records.count else { return false }
        errorMessage = nil
        guard save(next) else { return false }
        records = next
        items.removeAll { $0.id == id }
        return true
    }

    /// Refresh availability and renew stale bookmarks without discarding missing files.
    func refresh() {
        var refreshed = records
        var nextItems: [FileShelfItem] = []
        for index in refreshed.indices {
            var availableURL: URL?
            if let result = try? bookmarkCodec.resolve(refreshed[index].bookmark), result.url.isFileURL {
                let accessed = bookmarkCodec.startAccess(result.url)
                defer { if accessed { bookmarkCodec.stopAccess(result.url) } }
                if FileManager.default.fileExists(atPath: result.url.path),
                   FileManager.default.isReadableFile(atPath: result.url.path) {
                    availableURL = result.url
                    refreshed[index].name = result.url.lastPathComponent
                    refreshed[index].originalPath = Self.identity(result.url)
                    if result.isStale {
                        if let bookmark = try? bookmarkCodec.create(result.url) {
                            refreshed[index].bookmark = bookmark
                        } else {
                            errorMessage = "Dosya erişimi yenilenemedi: \(refreshed[index].name)"
                        }
                    }
                }
            }
            nextItems.append(FileShelfItem(id: refreshed[index].id, name: refreshed[index].name,
                                           url: availableURL))
        }
        if refreshed != records, save(refreshed) { records = refreshed }
        items = nextItems
    }

    func clearError() { errorMessage = nil }

    private static func identity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            // Retain the original bytes until the archive has been validated.
            recoveryData = data
            // Decode each record independently so a malformed entry cannot hide
            // otherwise valid files. Unsupported/corrupt bytes are preserved
            // separately before any subsequent mutation.
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["version"] as? Int == 1,
                  let entries = root["items"] as? [Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            var seen = Set<UUID>()
            for entry in entries {
                guard JSONSerialization.isValidJSONObject(entry),
                      let entryData = try? JSONSerialization.data(withJSONObject: entry),
                      let record = try? JSONDecoder().decode(Record.self, from: entryData),
                      !record.name.isEmpty, !record.bookmark.isEmpty,
                      seen.insert(record.id).inserted else {
                    errorMessage = "Depodaki bazı kayıtlar okunamadı."
                    continue
                }
                records.append(record)
            }
            if errorMessage == nil { recoveryData = nil }
        } catch {
            archiveCouldNotBeRead = recoveryData == nil
            errorMessage = "Dosya deposu okunamadı."
        }
    }

    private func save(_ records: [Record]) -> Bool {
        do {
            // Never replace an archive that could not even be read, and preserve
            // malformed data before committing a repaired/new collection.
            guard !archiveCouldNotBeRead else { throw CocoaError(.fileReadUnknown) }
            let data = try JSONEncoder().encode(Archive(version: 1, items: records))
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let recoveryData {
                let recoveryURL = storageURL.deletingLastPathComponent()
                    .appendingPathComponent("FileShelf-recovery-\(UUID().uuidString).json")
                try recoveryData.write(to: recoveryURL, options: .atomic)
            }
            try data.write(to: storageURL, options: .atomic)
            recoveryData = nil
            return true
        } catch {
            errorMessage = "Dosya deposu kaydedilemedi. Lütfen tekrar deneyin."
            return false
        }
    }
}
