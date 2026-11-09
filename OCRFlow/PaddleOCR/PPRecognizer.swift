import Foundation

/// CTC text recogniser (PP-OCRv6 rec) with PaddleOCR's aspect-ratio batching.
struct PPRecognizer {
    let session: PPSession
    /// Index 0 is the CTC blank, then the dictionary, then the space character —
    /// the layout `CTCLabelDecode` builds from `character_dict`.
    let charset: [String]

    init(session: PPSession, dictionaryURL: URL) throws {
        self.session = session
        guard let raw = try? String(contentsOf: dictionaryURL, encoding: .utf8) else {
            throw PPOCRError.dictionaryMissing
        }
        var characters = raw.components(separatedBy: "\n")
        if characters.last == "" { characters.removeLast() }
        guard !characters.isEmpty else { throw PPOCRError.dictionaryMissing }
        self.charset = ["<blank>"] + characters + [" "]
    }

    struct Result {
        var text: String
        var confidence: Double
    }

    /// PaddleOCR's `rec_batch_num`. It decides more than speed: every line
    /// in a group is padded to the width of the widest one, and the model
    /// reads a line differently with and without that padding — a trailing
    /// full stop, a space before a digit. Groups are therefore always formed
    /// exactly as the reference forms them.
    static let groupSize = 6

    func recognize(_ crops: [PPImageBuffer], config: PPOCRConfig) throws -> [Result] {
        guard !crops.isEmpty else { return [] }

        let imgH = max(1, config.recImageHeight)
        let baseW = max(1, config.recImageWidth)
        func ratio(_ i: Int) -> Double {
            Double(crops[i].width) / Double(max(crops[i].height, 1))
        }

        // The width each line is padded to, worked out exactly as the
        // reference batches: similar aspect ratios grouped together, every
        // line padded to its group's widest, and never narrower than the
        // model's base width.
        let order = crops.indices.sorted { ratio($0) < ratio($1) }
        var paddedWidth = [Int](repeating: 0, count: crops.count)
        for start in stride(from: 0, to: order.count, by: Self.groupSize) {
            let group = order[start..<min(start + Self.groupSize, order.count)]
            let maxRatio = group.reduce(Double(baseW) / Double(imgH)) { max($0, ratio($1)) }
            let width = max(1, Int(Double(imgH) * maxRatio))
            for i in group { paddedWidth[i] = width }
        }

        // Each line then goes to the model on its own, several at once. The
        // tensor a line is read from is the one it would have had inside its
        // group; only the scheduling differs. A small single-line graph keeps
        // one core busy far better than it keeps eight busy, so lines run
        // side by side on single-threaded calls — about twice the throughput
        // of one line at a time across every core.
        var results = [Result](repeating: Result(text: "", confidence: 0), count: crops.count)
        let queue = WorkQueue()
        let workers = min(crops.count, Self.workerCount(config))
        // Read-only from here on, and each worker writes only the slot of the
        // line it claimed, so sharing them across the workers is safe.
        nonisolated(unsafe) let crops = crops
        let widths = paddedWidth
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while let i = queue.claim(), i < crops.count {
                    do {
                        slots[i] = try read(crops[i], paddedTo: widths[i], height: imgH)
                    } catch {
                        queue.fail(error)
                    }
                }
            }
        }
        if let firstError = queue.firstError { throw firstError }
        return results
    }

    /// Hands out line indices to the workers, and stops handing them out
    /// once one line has failed.
    private final class WorkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var error: Error?

        /// The next line to read, or nil once a line has failed.
        func claim() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard error == nil else { return nil }
            next += 1
            return next - 1
        }

        func fail(_ error: Error) {
            lock.lock()
            if self.error == nil { self.error = error }
            lock.unlock()
        }

        var firstError: Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    /// How many lines are read at once: one per core unless the settings name
    /// a thread count. The efficiency cores are slower, but each worker takes
    /// the next line as soon as it is free, so they still add throughput —
    /// about an eighth more than the performance cores alone.
    static func workerCount(_ config: PPOCRConfig) -> Int {
        if config.threadCount > 0 { return config.threadCount }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Reads one line, padded to `width` the way its group would pad it.
    private func read(_ crop: PPImageBuffer, paddedTo width: Int, height: Int) throws -> Result {
        let ratio = Double(crop.width) / Double(max(crop.height, 1))
        let wanted = Int(ceil(Double(height) * ratio))
        let targetW = wanted > width ? width : max(1, wanted)
        let scaled = crop.resized(toWidth: targetW, height: height)
        var tensor = [Float](repeating: 0, count: 3 * height * width)
        // (x / 255 - 0.5) / 0.5, i.e. the recogniser's own normalisation
        // rather than the ImageNet statistics used by det and cls.
        scaled.writeNormalizedCHW(into: &tensor, offset: 0,
                                  mean: (0.5, 0.5, 0.5), std: (0.5, 0.5, 0.5),
                                  padTo: width, padHeight: height)

        let (values, shape) = try session.run(input: tensor, shape: [1, 3, height, width])
        guard shape.count == 3, shape[0] == 1 else {
            throw PPOCRError.unexpectedOutputShape(String(localized: "Recognition model output shape \(String(describing: shape))"))
        }
        let steps = shape[1], classes = shape[2]
        // A recogniser and a dictionary from different releases decode into
        // plausible-looking gibberish rather than failing, so refuse the
        // pairing outright the first time the shape is known.
        guard classes == charset.count else {
            throw PPOCRError.charsetMismatch(expected: charset.count, actual: classes)
        }
        return Self.ctcDecode(values, base: 0, steps: steps, classes: classes, charset: charset)
    }

    /// Greedy CTC decoding: take the arg-max per timestep, collapse repeats,
    /// drop blanks, and average the kept probabilities into a confidence.
    static func ctcDecode(_ values: [Float], base: Int, steps: Int, classes: Int,
                          charset: [String]) -> Result {
        var text = ""
        var probSum: Double = 0
        var kept = 0
        var previous = -1

        for t in 0..<steps {
            let row = base + t * classes
            var best = 0
            var bestValue = values[row]
            for c in 1..<classes where values[row + c] > bestValue {
                bestValue = values[row + c]
                best = c
            }
            defer { previous = best }
            guard best != 0, best != previous else { continue }
            if best < charset.count { text += charset[best] }
            probSum += Double(bestValue)
            kept += 1
        }
        return Result(text: text, confidence: kept > 0 ? probSum / Double(kept) : 0)
    }
}
