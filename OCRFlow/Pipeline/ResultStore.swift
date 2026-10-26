import Foundation
import CryptoKit

/// Keeps the queue and its results on disk.
///
/// Two things live here. The *queue* — every file in the list, its status and
/// its result, corrections included — so quitting the app, or a crash halfway
/// through a batch of a thousand files, loses nothing: the next launch picks
/// up where this one stopped. And a *cache* of recognitions keyed by what was
/// read and how — the file's bytes, the engine and every setting that changes
/// the output — so a file read once is not read again: not when it is added a
/// second time, not when it was renamed, not when it sits in two folders.
///
/// All disk work happens on a private serial queue; callers hand over values
/// and move on.
final class ResultStore: @unchecked Sendable {

    /// Bumped whenever the pipelines change what they produce for the same
    /// input, so a cached result from an older build is not served as current.
    static let pipelineVersion = 2

    let directory: URL
    private var resultsDirectory: URL { directory.appendingPathComponent("Results", isDirectory: true) }
    private var cacheDirectory: URL { directory.appendingPathComponent("Cache", isDirectory: true) }
    private var queueFile: URL { directory.appendingPathComponent("queue.json") }
    private let io = DispatchQueue(label: "OCRFlow.store", qos: .utility)

    /// How many cached recognitions are kept before the oldest go.
    private let cacheLimit = 5_000

    init(directory: URL = ResultStore.defaultDirectory) {
        self.directory = directory
        for folder in [directory, resultsDirectory, cacheDirectory] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    static var defaultDirectory: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["OCRFLOW_LIBRARY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OCRFlow/Library", isDirectory: true)
    }

    // MARK: - Queue

    private struct Entry: Codable {
        var id: UUID
        var path: String
        var root: String?
        var status: ProcessingStatus
        var engine: OCREngine?
        var elapsed: TimeInterval?
        var errorMessage: String?
    }

    /// Writes the list itself: which files, in which order, in which state.
    func saveQueue(_ items: [ImageItem]) {
        let entries = items.map { item in
            Entry(id: item.id, path: item.url.path, root: item.root?.path,
                  // A file being read when the app went away was not read.
                  status: item.status == .processing ? .pending : item.status,
                  engine: item.engine, elapsed: item.elapsed, errorMessage: item.errorMessage)
        }
        io.async { [queueFile] in
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: queueFile, options: .atomic)
        }
    }

    /// Writes one item's pages. Called when a result lands and whenever it is
    /// corrected.
    func save(_ item: ImageItem) {
        let pages = item.pages
        let file = resultFile(for: item.id)
        io.async {
            guard !pages.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            guard let data = try? JSONEncoder().encode(pages) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    func remove(_ ids: [UUID]) {
        let files = ids.map(resultFile(for:))
        io.async {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Reads the list back, results and all. Slow for a large library —
    /// call it off the main actor.
    func load() -> [ImageItem] {
        io.sync {}   // let pending writes land first
        guard let data = try? Data(contentsOf: queueFile),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        let decoder = JSONDecoder()
        return entries.map { entry in
            var item = ImageItem(url: URL(fileURLWithPath: entry.path),
                                 root: entry.root.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                 id: entry.id)
            item.status = entry.status
            item.engine = entry.engine
            item.elapsed = entry.elapsed
            item.errorMessage = entry.errorMessage
            // Only a finished file's result is shown; anything else is about
            // to be read again.
            if item.status == .completed, let data = try? Data(contentsOf: resultFile(for: entry.id)),
               let pages = try? decoder.decode([PageResult].self, from: data) {
                item.pages = pages
            } else if item.status == .completed {
                // The result went missing; the file is read again.
                item.status = .pending
            }
            return item
        }
    }

    /// Deletes the stored results of files no longer in the list — what a
    /// crash between removing a file and deleting its result leaves behind.
    func pruneResults(keeping ids: Set<UUID>) {
        io.async { [resultsDirectory] in
            let files = (try? FileManager.default.contentsOfDirectory(at: resultsDirectory,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                if id.map(ids.contains) != true { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    private func resultFile(for id: UUID) -> URL {
        resultsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Recognition cache

    /// The key for a file read with a given set of settings: a digest of its
    /// bytes and of the settings. Nil when the file cannot be read.
    static func cacheKey(for url: URL, fingerprint: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        hasher.update(data: Data(fingerprint.utf8))
        hasher.update(data: Data("v\(pipelineVersion)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func cachedPages(for key: String) -> [PageResult]? {
        let file = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: file),
              let pages = try? JSONDecoder().decode([PageResult].self, from: data) else { return nil }
        // Touched, so the pruning below keeps what is still being used.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return pages
    }

    func cache(_ pages: [PageResult], for key: String) {
        let file = cacheDirectory.appendingPathComponent("\(key).json")
        io.async { [cacheDirectory, cacheLimit] in
            guard let data = try? JSONEncoder().encode(pages) else { return }
            try? data.write(to: file, options: .atomic)

            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: keys),
                  files.count > cacheLimit else { return }
            let dated = files.map { file in
                (file, (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast)
            }
            for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - cacheLimit) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Empties the recognition cache. The queue and its results stay.
    func clearCache() {
        io.async { [cacheDirectory] in
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
}
