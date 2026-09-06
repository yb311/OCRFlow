import Foundation

/// Installs catalog entries into the user models folder.
///
/// Files are streamed to a temporary location and only moved into place once
/// the whole download has arrived, so an interrupted transfer can never leave
/// a half-written model that the engine would then try to load.
@MainActor
final class PPModelDownloader: ObservableObject {

    @Published var source: PPModelCatalog.Source = .huggingFace
    /// 0…1 per entry id, present only while that entry is downloading.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    /// What a reachability check made of each source, so the mirror can be
    /// shown to work — or not — before a gigabyte of download depends on it.
    @Published private(set) var reachability: [PPModelCatalog.Source: Reachability] = [:]

    enum Reachability: Equatable {
        case checking
        /// Round trip in milliseconds.
        case reachable(Int)
        case unreachable(String)

        var isChecking: Bool { self == .checking }
    }
    /// Bumped whenever the models folder changes, so views recompute the
    /// installed state of every entry.
    @Published private(set) var inventoryVersion = 0

    private var tasks: [String: Task<Void, Never>] = [:]

    func isDownloading(_ entry: PPModelCatalog.Entry) -> Bool {
        tasks[entry.id] != nil
    }

    func download(_ entry: PPModelCatalog.Entry) {
        guard tasks[entry.id] == nil else { return }
        errors[entry.id] = nil
        progress[entry.id] = 0

        let source = self.source
        let destination = PPModelStore.userModelsDirectory
        PPModelStore.ensureUserModelsDirectory()

        let id = entry.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress[id] = fraction }
        }

        let fallback = PPModelCatalog.Source.allCases.first { $0 != source }

        tasks[id] = Task.detached(priority: .utility) { [weak self] in
            var failure: String?
            do {
                try await Self.install(entry, from: source, into: destination, progress: report)
                failure = nil
            } catch is CancellationError {
                // Leaving no error message reads as "the user stopped it".
                failure = nil
            } catch {
                // One host being unreachable is the common case here — either
                // Hugging Face from mainland China, or the mirror lagging a
                // fresh upload — and the other one usually has the same file.
                if let fallback, !Task.isCancelled {
                    do {
                        try await Self.install(entry, from: fallback, into: destination, progress: report)
                        failure = nil
                    } catch is CancellationError {
                        failure = nil
                    } catch let retryError {
                        failure = "\(error.localizedDescription)；已改用\(fallback.label)重试，"
                                + "仍然失败：\(retryError.localizedDescription)"
                    }
                } else {
                    failure = error.localizedDescription
                }
            }
            await self?.finish(id, error: failure)
        }
    }

    func cancel(_ entry: PPModelCatalog.Entry) {
        tasks[entry.id]?.cancel()
    }

    /// Asks each source for the headers of one small file.
    ///
    /// The mirror is the only way to reach these models from a lot of networks,
    /// and "the download failed" is a poor way to find out that the host itself
    /// is unreachable.
    func testSources() {
        for source in PPModelCatalog.Source.allCases {
            reachability[source] = .checking
            Task { [weak self] in
                let result = await Self.probe(source)
                await MainActor.run { self?.reachability[source] = result }
            }
        }
    }

    /// A HEAD against a file that exists in every mirror of the catalogue.
    private nonisolated static func probe(_ source: PPModelCatalog.Source) async -> Reachability {
        guard let url = PPModelCatalog.probeAsset.url(from: source) else {
            return .unreachable("地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else { return .unreachable("无响应") }
            guard (200..<400).contains(http.statusCode) else {
                return .unreachable("HTTP \(http.statusCode)")
            }
            return .reachable(milliseconds)
        } catch {
            return .unreachable((error as NSError).localizedDescription)
        }
    }

    /// Deletes every file the entry installed.
    func remove(_ entry: PPModelCatalog.Entry) {
        for asset in entry.assets {
            let url = PPModelStore.userModelsDirectory.appendingPathComponent(asset.localName)
            try? FileManager.default.removeItem(at: url)
        }
        errors[entry.id] = nil
        inventoryVersion += 1
    }

    private func finish(_ id: String, error: String?) {
        tasks[id] = nil
        progress[id] = nil
        errors[id] = error
        inventoryVersion += 1
    }

    // MARK: - Transfer

    private nonisolated static func install(_ entry: PPModelCatalog.Entry,
                                            from source: PPModelCatalog.Source,
                                            into destination: URL,
                                            progress: @escaping @Sendable (Double) -> Void) async throws {
        // Assemble everything in a scratch folder first: a model without its
        // dictionary is worse than no model at all, because the engine loads it
        // and then decodes gibberish.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRFlowDownload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let total = Double(entry.assets.count)
        for (index, asset) in entry.assets.enumerated() {
            guard let url = asset.url(from: source) else {
                throw PPDownloadError.badURL(asset.remoteFile)
            }
            let staged = staging.appendingPathComponent(asset.localName)
            try await downloadFile(from: url, to: staged) { fraction in
                progress((Double(index) + fraction) / total)
            }
            if asset.kind == .dictionary {
                // `inference.yml` carries the charset; the app writes it out in
                // the one-character-per-line form `PPRecognizer` reads.
                guard let yaml = try? String(contentsOf: staged, encoding: .utf8) else {
                    throw PPDownloadError.malformedDictionary(asset.remoteFile)
                }
                try PPDictionary.writeDictionary(fromInferenceYAML: yaml, to: staged)
            }
        }

        for asset in entry.assets {
            let from = staging.appendingPathComponent(asset.localName)
            let to = destination.appendingPathComponent(asset.localName)
            if FileManager.default.fileExists(atPath: to.path) {
                _ = try FileManager.default.replaceItemAt(to, withItemAt: from)
            } else {
                try FileManager.default.moveItem(at: from, to: to)
            }
        }
        progress(1)
    }

    /// Downloads `url` to `file`. A download task rather than `URLSession.bytes`:
    /// the byte sequence is iterated one element at a time, which costs more
    /// than the transfer itself on a 139 MB model.
    private nonisolated static func downloadFile(from url: URL, to file: URL,
                                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let observer = DownloadObserver(onProgress: progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: observer)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw PPDownloadError.httpStatus(http.statusCode, url.host ?? "")
        }

        // A transfer cut short but still reported as 200 would otherwise be
        // installed as a valid model.
        let expected = response.expectedContentLength
        let written = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? nil
        if expected > 0, let written, written != expected {
            try? FileManager.default.removeItem(at: temporary)
            throw PPDownloadError.truncated(received: written, expected: expected)
        }

        do {
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PPDownloadError.cannotWrite(file.lastPathComponent)
        }
        progress(1)
    }
}

/// Reports how far a download task has got, as the 0…1 fraction the UI shows.
///
/// `download(from:delegate:)` hands the per-task delegate only the
/// `URLSessionTaskDelegate` callbacks — `didWriteData` is a *download*-delegate
/// method and never arrives — so the byte counts come from the task's own
/// `Progress` instead.
private final class DownloadObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    deinit { observation?.invalidate() }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let report = onProgress
        observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            report(min(1, max(0, progress.fractionCompleted)))
        }
    }
}

enum PPDownloadError: LocalizedError {
    case badURL(String)
    case httpStatus(Int, String)
    case cannotWrite(String)
    case truncated(received: Int64, expected: Int64)
    case malformedDictionary(String)

    var errorDescription: String? {
        switch self {
        case let .badURL(file):
            return "无法构造 \(file) 的下载地址"
        case let .httpStatus(code, host):
            return code == 404
                ? "\(host) 上找不到该文件（HTTP 404）"
                : "\(host) 返回 HTTP \(code)，请稍后重试或切换下载源"
        case let .cannotWrite(name):
            return "无法写入文件 \(name)"
        case let .truncated(received, expected):
            return "下载不完整：收到 \(received) 字节，应为 \(expected) 字节"
        case let .malformedDictionary(file):
            return "无法从 \(file) 中解析字符字典"
        }
    }
}
