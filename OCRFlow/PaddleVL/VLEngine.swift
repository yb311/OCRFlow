import Foundation
import CoreGraphics
import llama

/// Runs the PaddleOCR-VL-1.6 vision-language model locally through llama.cpp.
///
/// Loading the weights costs seconds and a gigabyte or more of memory, so an
/// engine is built once per configuration and reused. Every entry point is
/// serialised behind a lock — the same arrangement `PPOCREngine` uses, and for
/// a stronger reason here: one `llama_context` holds a single KV cache, so two
/// concurrent generations would corrupt each other's state.
final class VLEngine: @unchecked Sendable {

    let config: VLConfig

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let multimodal: OpaquePointer
    private let vocab: OpaquePointer
    private let lock = NSLock()

    /// llama.cpp's backend registry is process-global and must be initialised
    /// once before any model is loaded.
    private static let backendReady: Bool = {
        llama_backend_init()
        // The library is chatty on stderr by default; the app has its own error
        // reporting and does not want a running commentary.
        llama_log_set({ level, _, _ in _ = level }, nil)
        // mtmd logs through its own channel, which llama_log_set does not cover.
        mtmd_helper_log_set({ level, _, _ in _ = level }, nil)
        return true
    }()

    convenience init(config: VLConfig) throws {
        try self.init(config: config, paths: VLModelStore.resolve(variant: config.variant))
    }

    init(config: VLConfig, paths: VLModelStore.Paths) throws {
        self.config = config
        _ = Self.backendReady

        var modelParams = llama_model_default_params()
        // Negative means "put every layer on the GPU"; on Apple Silicon that is
        // Metal, which is several times faster than the CPU path.
        modelParams.n_gpu_layers = config.useGPU ? -1 : 0
        guard let model = llama_model_load_from_file(paths.model.path, modelParams) else {
            throw VLError.backendFailed("无法加载 \(paths.model.lastPathComponent)")
        }
        self.model = model

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(max(2048, config.contextTokens))
        // A page's image expands into thousands of tokens that are submitted in
        // one go, so the batch has to be as large as the context.
        contextParams.n_batch = contextParams.n_ctx
        contextParams.n_ubatch = min(contextParams.n_batch, 512)
        if config.threadCount > 0 {
            contextParams.n_threads = Int32(config.threadCount)
            contextParams.n_threads_batch = Int32(config.threadCount)
        }
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw VLError.contextFailed("上下文长度 \(contextParams.n_ctx)")
        }
        self.context = context

        var mtmdParams = mtmd_context_params_default()
        mtmdParams.use_gpu = config.useGPU
        mtmdParams.print_timings = false
        if config.threadCount > 0 { mtmdParams.n_threads = Int32(config.threadCount) }
        guard let multimodal = mtmd_init_from_file(paths.mmproj.path, model, mtmdParams) else {
            llama_free(context)
            llama_model_free(model)
            throw VLError.multimodalFailed("无法加载 \(paths.mmproj.lastPathComponent)")
        }
        self.multimodal = multimodal

        guard let vocab = llama_model_get_vocab(model) else {
            mtmd_free(multimodal)
            llama_free(context)
            llama_model_free(model)
            throw VLError.backendFailed("模型没有词表")
        }
        self.vocab = vocab
    }

    deinit {
        mtmd_free(multimodal)
        llama_free(context)
        llama_model_free(model)
    }

    /// True when `other` would build an equivalent engine, so the loaded
    /// weights can be reused instead of paying the load cost again.
    func matchesModelConfiguration(_ other: VLConfig) -> Bool {
        config.variant == other.variant
            && config.contextTokens == other.contextTokens
            && config.useGPU == other.useGPU
            && config.threadCount == other.threadCount
    }

    // MARK: - Recognition

    /// Reads one image with the prompt for `task`.
    ///
    /// `onToken` receives each decoded piece as it is produced, which is what
    /// lets the UI show a page filling in rather than freezing for a minute.
    func recognize(image: CGImage,
                   crop: CGRect? = nil,
                   task: VLTask,
                   maxTokens: Int? = nil,
                   isCancelled: (() -> Bool)? = nil,
                   onToken: ((String) -> Void)? = nil) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let buffer = VLImageBuffer(cgImage: image, cropping: crop) else {
            throw VLError.imageDecodeFailed
        }

        // Each call starts from a clean slate; leftover KV entries from the
        // previous block would be read as context for this one.
        llama_memory_clear(llama_get_memory(context), true)

        guard let bitmap = buffer.pixels.withUnsafeBufferPointer({
            mtmd_bitmap_init(UInt32(buffer.width), UInt32(buffer.height), $0.baseAddress)
        }) else {
            throw VLError.imageDecodeFailed
        }
        defer { mtmd_bitmap_free(bitmap) }

        guard let chunks = mtmd_input_chunks_init() else {
            throw VLError.multimodalFailed("无法创建输入块")
        }
        defer { mtmd_input_chunks_free(chunks) }

        var nPast = try tokenizeAndEval(prompt: Self.prompt(for: task, marker: marker),
                                        bitmap: bitmap, chunks: chunks)

        return try generate(from: &nPast,
                            limit: maxTokens ?? config.maxOutputTokens,
                            isCancelled: isCancelled,
                            onToken: onToken)
    }

    private var marker: String {
        String(cString: mtmd_get_marker(multimodal) ?? mtmd_default_marker())
    }

    /// PaddleOCR-VL's chat template, applied by hand.
    ///
    /// The template shipped with the model is custom enough that llama.cpp
    /// refuses it without a Jinja engine, but its shape is simple and fixed, so
    /// building the string directly avoids dragging that dependency in.
    private static func prompt(for task: VLTask, marker: String) -> String {
        "<|begin_of_sentence|>User: \(marker)\(task.prompt)\nAssistant:\n"
    }

    private func tokenizeAndEval(prompt: String,
                                 bitmap: OpaquePointer,
                                 chunks: OpaquePointer) throws -> llama_pos {
        var status: Int32 = 0
        prompt.withCString { text in
            var input = mtmd_input_text(text: text, text_len: strlen(text),
                                        add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            status = bitmaps.withUnsafeMutableBufferPointer { buf in
                mtmd_tokenize(multimodal, chunks, &input, buf.baseAddress, 1)
            }
        }
        guard status == 0 else { throw VLError.tokenizeFailed(status) }

        var nPast: llama_pos = 0
        let evaluated = mtmd_helper_eval_chunks(multimodal, context, chunks,
                                                0, 0, Int32(config.contextTokens),
                                                true, &nPast)
        guard evaluated == 0 else { throw VLError.evalFailed(evaluated) }
        return nPast
    }

    /// Greedy decoding. PaddleOCR-VL is a transcription model, so there is
    /// nothing to gain from sampling — the reference pipeline runs at
    /// temperature 0 and so do we.
    private func generate(from nPast: inout llama_pos,
                          limit: Int,
                          isCancelled: (() -> Bool)?,
                          onToken: ((String) -> Void)?) throws -> String {
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        // Tokens are byte sequences, not characters: a single CJK or Hangul
        // character spans three bytes and is routinely split across two
        // tokens. Decoding each token on its own turns every such character
        // into U+FFFD, so the bytes are accumulated and only decoded once they
        // form complete scalars.
        var bytes: [UInt8] = []
        var emitted = 0
        var piece = [CChar](repeating: 0, count: 256)
        // Kept alongside the bytes so a runaway tail can be cut back off the
        // output, not merely stopped.
        var tokens: [llama_token] = []
        var pieceLengths: [Int] = []

        for _ in 0..<max(1, limit) {
            if isCancelled?() == true { break }

            guard let logits = llama_get_logits_ith(context, -1) else { break }
            var best = llama_token(0)
            var bestValue = -Float.greatestFiniteMagnitude
            for id in 0..<vocabSize where logits[id] > bestValue {
                bestValue = logits[id]
                best = llama_token(id)
            }
            if llama_vocab_is_eog(vocab, best) { break }

            let written = piece.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocab, best, $0.baseAddress, Int32($0.count), 0, false)
            }
            tokens.append(best)
            pieceLengths.append(Int(max(0, written)))
            if written > 0 {
                piece.withUnsafeBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(written)) {
                        bytes.append(contentsOf: UnsafeBufferPointer(start: $0, count: Int(written)))
                    }
                }
                // A nil here means the tail is a partial character; hold it back
                // until the next token completes it.
                if let text = String(bytes: bytes[emitted...], encoding: .utf8) {
                    if !text.isEmpty { onToken?(text) }
                    emitted = bytes.count
                }
            }

            // Greedy decoding on a dense block sometimes falls into a loop and
            // then spends the whole token budget on it — which is what turned
            // the bottom of a page into the same line over and over. Stop at
            // the loop and drop everything but its first pass.
            if let loop = Self.runawayRepeat(in: tokens) {
                let discard = (loop.repeats - 1) * loop.period
                let removedBytes = pieceLengths.suffix(discard).reduce(0, +)
                bytes.removeLast(min(removedBytes, bytes.count))
                break
            }

            var token = best
            let batch = llama_batch_get_one(&token, 1)
            guard llama_decode(context, batch) == 0 else { break }
            nPast += 1
        }

        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detects a degenerate loop at the tail: the last `period` tokens repeated
    /// `repeats` times over.
    ///
    /// Short cycles have to repeat more often before they count — a table row
    /// of empty cells is a handful of tokens repeating legitimately, while a
    /// stuck decoder repeats until the budget runs out. Nothing shorter than
    /// four passes is ever treated as a loop, so ordinary repetition survives.
    private static func runawayRepeat(in tokens: [llama_token]) -> (period: Int, repeats: Int)? {
        for period in 1...16 {
            let repeats = period >= 5 ? 4 : 8
            guard tokens.count >= period * repeats else { continue }
            var isLoop = true
            check: for pass in 1..<repeats {
                for offset in 0..<period {
                    let last = tokens[tokens.count - offset - 1]
                    let earlier = tokens[tokens.count - offset - 1 - period * pass]
                    if last != earlier {
                        isLoop = false
                        break check
                    }
                }
            }
            if isLoop { return (period, repeats) }
        }
        return nil
    }
}
