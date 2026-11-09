import Foundation
import OnnxRuntimeBindings
import os

/// Runs PP-DocLayoutV3 on the GPU, about three times faster than on the CPU
/// with the same boxes, labels and reading order.
///
/// The graph cannot go to the GPU whole. Core ML refuses one of its pooling
/// nodes outright, and the last stretch of the graph — the post-processing
/// that turns queries into ranked detections, where the reading-order key
/// is made — comes back from Core ML with the order scrambled while every
/// box is right. So the downloaded file is cut in two before that stretch:
/// the backbone, encoder and decoder run on the GPU, and the 170-odd nodes
/// after the cut run on the CPU, where they cost a few milliseconds.
///
/// Compiling for the GPU takes ten seconds the first time and a couple of
/// seconds on later launches, so it happens in the background; until it is
/// done, and whenever it is not possible, layout runs on the CPU as before.
final class PPLayoutAccelerator: @unchecked Sendable {

    /// The first node of the post-processing stretch. Cutting anywhere from
    /// a little before it to a little after gives identical output; it is
    /// used as the cut because it can be found by name.
    static let splitAnchor = "Einsum.0"

    /// One accelerator per model file, shared by every engine that loads it:
    /// PP-OCR's reading order, 智能分层 and PaddleOCR-VL all use the same
    /// layout model, and compiling it once is enough.
    static func shared(for modelPath: URL) -> PPLayoutAccelerator? {
        #if arch(arm64)
        guard ORTIsCoreMLExecutionProviderAvailable() else { return nil }
        let key = modelPath.standardizedFileURL.path(percentEncoded: false)
        // A model downloaded again over the same path is a different file:
        // the stages cut from the old one would run the old weights while
        // the CPU session reads the new ones.
        let identity = fileIdentity(modelPath)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key], existing.identity == identity { return existing.accelerator }
        let accelerator = PPLayoutAccelerator(modelPath: modelPath)
        registry[key] = (identity, accelerator)
        accelerator.prepareInBackground()
        return accelerator
        #else
        return nil
        #endif
    }

    /// Starts getting the GPU stages ready for the installed layout model, if
    /// there is one. Called at launch and after a download, so that the
    /// couple of seconds it takes are over before the first page arrives.
    static func prepareInstalledModel() {
        guard let url = try? VLModelStore.resolveLayoutModel() else { return }
        _ = shared(for: url)
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: (identity: String, accelerator: PPLayoutAccelerator)] = [:]

    /// Size and modification date: what `cacheDirectory()` keys on as well.
    private static func fileIdentity(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(modified)"
    }
    private static let log = Logger(subsystem: "com.ocrflow.app", category: "LayoutGPU")

    private struct Stages {
        var env: ORTEnv
        var head: PPSession
        var tail: PPSession
    }

    private let modelPath: URL
    private let lock = NSLock()
    private var stages: Stages?

    /// A shared `flock` on the cache directory's lock file, held for as long
    /// as this accelerator lives. Set once, by `loadStages()`.
    private var cacheLock: Int32 = -1

    private init(modelPath: URL) {
        self.modelPath = modelPath
    }

    deinit {
        if cacheLock >= 0 { close(cacheLock) }
    }

    /// True once the GPU stages are loaded.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stages != nil
    }

    private func prepareInBackground() {
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                let loaded = try loadStages()
                lock.lock()
                stages = loaded
                lock.unlock()
            } catch {
                Self.log.error("Layout stays on the CPU: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Runs the graph on the GPU stages. Nil while they are not ready, which
    /// tells the caller to use its CPU session.
    func run(inputs: [String: PPTensor], outputNames: [String]) throws -> [String: PPTensor]? {
        lock.lock()
        let stages = stages
        lock.unlock()
        guard let stages else { return nil }

        let (values, backing) = try PPSession.values(inputs)
        let middle = try stages.head.run(values: values.filter { stages.head.inputNames.contains($0.key) },
                                         outputNames: stages.head.outputNames)
        var tailInputs = values.filter { stages.tail.inputNames.contains($0.key) }
        tailInputs.merge(middle) { _, new in new }
        let outputs = try stages.tail.run(values: tailInputs, outputNames: outputNames)
        withExtendedLifetime(backing) {}

        var result: [String: PPTensor] = [:]
        for name in outputNames {
            guard let value = outputs[name] else {
                throw PPOCRError.inferenceFailed(String(localized: "The model returned no output \(name)"))
            }
            result[name] = try PPSession.read(value, name: name)
        }
        return result
    }

    // MARK: - Loading

    private struct Manifest: Codable {
        /// Symbolic dimensions of the head's inputs, all of them batch axes.
        var batchDimensions: [String]
    }

    private func loadStages() throws -> Stages {
        let directory = try claimCacheDirectory()
        let headURL = directory.appending(path: "head.onnx")
        let tailURL = directory.appending(path: "tail.onnx")
        let manifestURL = directory.appending(path: "manifest.json")

        let manifest: Manifest
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder().decode(Manifest.self, from: data),
           FileManager.default.fileExists(atPath: headURL.path(percentEncoded: false)),
           FileManager.default.fileExists(atPath: tailURL.path(percentEncoded: false)) {
            manifest = saved
        } else {
            let model = try Data(contentsOf: modelPath, options: .mappedIfSafe)
            let halves = try ONNXGraphSplit.split(model, before: Self.splitAnchor)
            // Only a batch axis may be fixed: pinning any other symbolic
            // dimension to one would change what the graph computes.
            var batch: [String] = []
            for dimensions in halves.headInputDimensions.values {
                for (axis, name) in dimensions.enumerated() {
                    guard let name else { continue }
                    guard axis == 0 else { throw PPOCRError.sessionFailed("non-batch dimension \(name)") }
                    batch.append(name)
                }
            }
            manifest = Manifest(batchDimensions: Array(Set(batch)).sorted())
            try halves.head.write(to: headURL, options: .atomic)
            try halves.tail.write(to: tailURL, options: .atomic)
            // Written last, so a half-written pair is never taken as done.
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        }

        let env = try ORTEnv(loggingLevel: .error)
        let compiled = directory.appending(path: "coreml", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        let placement = PPSession.GPUPlacement(
            fixedDimensions: Dictionary(uniqueKeysWithValues: manifest.batchDimensions.map { ($0, 1) }),
            cacheDirectory: compiled)
        let head = try PPSession(modelPath: headURL, env: env, config: .default, gpu: placement)
        let tail = try PPSession(modelPath: tailURL, env: env, config: .default)
        return Stages(env: env, head: head, tail: tail)
    }

    /// The file inside each cache directory whose shared lock marks the
    /// directory as in use.
    private static let lockFileName = ".in-use"

    /// `cacheDirectory()`, locked against the cleanup below, after which the
    /// copies left by earlier model files and runtimes are removed.
    ///
    /// Every new download or ONNX Runtime gives a new directory, so without
    /// the cleanup they pile up a few hundred megabytes at a time. The lock
    /// is what keeps it from taking a directory still in use — by an
    /// accelerator for the previous download that a running engine holds,
    /// or by another copy of the app.
    private func claimCacheDirectory() throws -> URL {
        for _ in 0..<3 {
            let directory = try cacheDirectory()
            let lockPath = directory.appending(path: Self.lockFileName).path(percentEncoded: false)
            // Fails only if a cleanup removed the directory just after it
            // was created; the next pass creates it again.
            let descriptor = open(lockPath, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { continue }
            guard flock(descriptor, LOCK_SH) == 0 else {
                close(descriptor)
                continue
            }
            // A cleanup holding the lock first deletes the file before it
            // lets go; a lock on a deleted file protects nothing.
            var held = stat()
            var onDisk = stat()
            if fstat(descriptor, &held) == 0, stat(lockPath, &onDisk) == 0,
               held.st_dev == onDisk.st_dev, held.st_ino == onDisk.st_ino {
                cacheLock = descriptor
                Self.removeStaleCaches(keeping: directory)
                return directory
            }
            close(descriptor)
        }
        throw PPOCRError.sessionFailed("GPU cache directory could not be locked")
    }

    /// Deletes every sibling of `current` that nothing holds a lock on.
    private static func removeStaleCaches(keeping current: URL) {
        let fileManager = FileManager.default
        guard let siblings = try? fileManager.contentsOfDirectory(
            at: current.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles) else { return }
        for sibling in siblings where sibling.lastPathComponent != current.lastPathComponent {
            guard (try? sibling.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let descriptor = open(sibling.appending(path: lockFileName).path(percentEncoded: false),
                                  O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // Held shared by whoever is using it; leave it alone then.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            do {
                try fileManager.removeItem(at: sibling)
            } catch {
                log.error("Couldn't remove an old GPU cache: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A directory for this exact model file, cut and runtime. Anything that
    /// could make an old compiled model wrong for the current one — a new
    /// download, a different cut, a new ONNX Runtime — gives a new directory.
    private func cacheDirectory() throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: modelPath.path(percentEncoded: false))
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int64((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let runtime = ORTVersion() ?? "unknown"
        let name = [modelPath.deletingPathExtension().lastPathComponent, "\(size)", "\(modified)",
                    Self.splitAnchor, "ort\(runtime)", "v1"].joined(separator: "-")
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = root.appending(path: Bundle.main.bundleIdentifier ?? "com.ocrflow.app")
            .appending(path: "GPU").appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
