import Foundation
import CoreServices

/// Watches a folder — subfolders included — and hands over each new file once
/// it has finished arriving.
///
/// FSEvents says *that* something under the folder changed, not reliably
/// *what*: events are coalesced, repeated, and sometimes dropped. So an event
/// is only ever a reason to look again; what counts is a rescan of the folder.
/// A file is handed over once its size and modification date have stayed the
/// same across two looks a couple of seconds apart, so a scan still being
/// copied in is not read half-written.
///
/// Nothing in the watched folder is moved, renamed or deleted.
final class FolderWatcher {
    let folder: URL
    /// Never looked into: where results are written, when that is inside the
    /// watched folder, so writing a result cannot set off another reading.
    let excluded: URL?
    /// Asked before a file is handed over: false skips it for good — a file
    /// whose result is already in the output folder, say.
    private let shouldTake: (URL) -> Bool
    private let onFiles: ([URL]) -> Void

    private var stream: FSEventStreamRef?
    private var timer: Timer?
    /// Files seen but not yet still: path → what they looked like last time.
    private var pending: [String: (size: Int64, modified: Date)] = [:]
    /// Files already handed over or skipped.
    private var settled = Set<String>()

    /// How long a file has to hold still before it is taken.
    private let settleInterval: TimeInterval = 2

    init(folder: URL, excluding excluded: URL?, shouldTake: @escaping (URL) -> Bool,
         onFiles: @escaping ([URL]) -> Void) {
        self.folder = folder.standardizedFileURL
        self.excluded = excluded?.standardizedFileURL
        self.shouldTake = shouldTake
        self.onFiles = onFiles
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().rescan()
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                     [folder.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     1.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        // Whatever is already there is new to this session too.
        rescan()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    /// Looks at everything under the folder and hands over what has settled.
    private func rescan() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        var ready: [URL] = []
        var stillMoving = false
        let excludedPath = excluded.map { $0.path + "/" }
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            if let excludedPath, path.hasPrefix(excludedPath) || path + "/" == excludedPath {
                walker.skipDescendants()
                continue
            }
            guard OCRViewModel.supportedExtensions.contains(url.pathExtension.lowercased()),
                  !settled.contains(path),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let now = (size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
            if let before = pending[path], before == now,
               Date().timeIntervalSince(now.modified) >= settleInterval {
                pending[path] = nil
                settled.insert(path)
                if shouldTake(url) { ready.append(url) }
            } else {
                pending[path] = now
                stillMoving = true
            }
        }
        if !ready.isEmpty {
            ready.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            onFiles(ready)
        }
        // Files still arriving are looked at again until they settle; FSEvents
        // says nothing more about a file that has simply stopped changing.
        timer?.invalidate()
        timer = stillMoving
            ? Timer.scheduledTimer(withTimeInterval: settleInterval, repeats: false) { [weak self] _ in
                self?.rescan()
            }
            : nil
    }
}
