import Foundation
import CoreGraphics
import Accelerate
import llama

/// One region for the model to read.
struct VLRequest {
    var image: CGImage
    /// The part of `image` to read, in its pixel coordinates; nil reads all of it.
    var crop: CGRect?
    var task: VLTask
    /// Overrides `VLConfig.maxOutputTokens` for this one region.
    var maxTokens: Int?
}

/// What the model read out of one region, and how it stopped.
///
/// The ending is kept because it is the only first-hand evidence the pipeline
/// has about a VLM answer: the model reports no confidence, but a block that
/// ran out of budget or had to be cut out of a loop is a block worth a second
/// look, and the quality check flags it for review.
struct VLOutput: Equatable {
    enum Ending: Equatable {
        /// The model ended its answer itself.
        case finished
        /// The token budget ran out first, so the text may be cut short.
        case lengthLimit
        /// The decoder fell into a loop; everything after its first pass was
        /// cut off.
        case repetition
        case cancelled
        /// llama.cpp refused a step. Whatever came before it is kept.
        case decodeFailed
    }

    var text: String
    var ending: Ending

    static let cancelled = VLOutput(text: "", ending: .cancelled)
}

/// Runs the PaddleOCR-VL-1.6 vision-language model locally through llama.cpp.
///
/// Loading the weights costs seconds and a gigabyte or more of memory, so an
/// engine is built once per configuration and reused.
///
/// ## Batching
///
/// A page is read region by region, and most of the time of each region goes
/// into generating its answer one token at a time. A single token step reads
/// every weight of the model to produce one token; a step over eight
/// sequences reads them once and produces eight. On Apple silicon that step
/// is bound by memory bandwidth, not arithmetic, so the extra sequences ride
/// along almost for free.
///
/// The engine therefore keeps one llama context with room for several
/// sequences and decodes them side by side — continuous batching: a region
/// that finishes hands its slot to the next one waiting, so the batch stays
/// full until the queue runs dry. Requests can come from several pages, and
/// from several files, at once; they all join the same batch.
///
/// Nothing about *what* is computed changes. Every region gets the same crop,
/// the same prompt and the same greedy decode it got when regions were read
/// one after another; only the order in which the GPU does the work differs.
///
/// All llama.cpp calls that touch the context happen on one dedicated thread,
/// which owns the KV cache. Callers only tokenise — which mtmd documents as
/// safe on a shared context — and wait.
final class VLEngine: @unchecked Sendable {

    let config: VLConfig
    /// How many regions are decoded side by side.
    var parallelism: Int { core.parallelism }

    private let core: Core

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

        let parallelism = config.resolvedParallelism
        // One request on its own must still get the context it always had, so
        // a region that fitted before batching still fits now.
        let perRequest = max(2048, config.contextTokens)
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(VLConfig.contextBudget(perRequest: perRequest,
                                                            parallelism: parallelism))
        contextParams.n_seq_max = UInt32(parallelism)
        // One pool of cells shared by every sequence, rather than a fixed slice
        // each: a full-page request and a one-line caption need very different
        // amounts, and the scheduler hands out room by what each one needs.
        contextParams.kv_unified = true
        // A region's image expands into hundreds or thousands of tokens that
        // are submitted in one go, so a submission has to be able to hold one.
        contextParams.n_batch = UInt32(perRequest)
        contextParams.n_ubatch = min(contextParams.n_batch, 512)
        if config.threadCount > 0 {
            contextParams.n_threads = Int32(config.threadCount)
            contextParams.n_threads_batch = Int32(config.threadCount)
        }
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw VLError.contextFailed("上下文长度 \(contextParams.n_ctx)")
        }

        var mtmdParams = mtmd_context_params_default()
        mtmdParams.use_gpu = config.useGPU
        mtmdParams.print_timings = false
        if config.threadCount > 0 { mtmdParams.n_threads = Int32(config.threadCount) }
        guard let multimodal = mtmd_init_from_file(paths.mmproj.path, model, mtmdParams) else {
            llama_free(context)
            llama_model_free(model)
            throw VLError.multimodalFailed("无法加载 \(paths.mmproj.lastPathComponent)")
        }

        guard let vocab = llama_model_get_vocab(model) else {
            mtmd_free(multimodal)
            llama_free(context)
            llama_model_free(model)
            throw VLError.backendFailed("模型没有词表")
        }

        core = Core(model: model, context: context, multimodal: multimodal, vocab: vocab,
                    config: config, parallelism: parallelism, submission: Int32(perRequest))
        core.start()
    }

    /// Stops the decode thread and frees the model before returning, so the
    /// view model can release an engine at quit and know llama.cpp has let go
    /// of its Metal device by the time static destructors run.
    deinit {
        core.shutdown()
    }

    /// True when `other` would build an equivalent engine, so the loaded
    /// weights can be reused instead of paying the load cost again.
    func matchesModelConfiguration(_ other: VLConfig) -> Bool {
        config.variant == other.variant
            && config.contextTokens == other.contextTokens
            && config.useGPU == other.useGPU
            && config.threadCount == other.threadCount
            && config.resolvedParallelism == other.resolvedParallelism
    }

    // MARK: - Recognition

    /// Reads several regions, decoding them side by side.
    ///
    /// Blocks until every request has an answer. Results come back in request
    /// order; `onResult` also reports each one as it lands, from whichever
    /// thread produced it, so a caller can move a progress bar.
    ///
    /// A region that cannot be read — a crop too small to decode, say — fails
    /// on its own and leaves the rest of the batch alone.
    func recognize(_ requests: [VLRequest],
                   isCancelled: (() -> Bool)? = nil,
                   onResult: ((Int, Result<VLOutput, Error>) -> Void)? = nil)
        -> [Result<VLOutput, Error>] {
        guard !requests.isEmpty else { return [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var results = [Result<VLOutput, Error>](repeating: .success(.cancelled),
                                                count: requests.count)
        func store(_ result: Result<VLOutput, Error>, at index: Int) {
            lock.lock()
            results[index] = result
            lock.unlock()
            onResult?(index, result)
        }

        for (index, request) in requests.enumerated() {
            // Requests not yet handed over when the run is stopped keep the
            // `cancelled` placeholder they were created with.
            if isCancelled?() == true { break }
            group.enter()
            do {
                // Tokenising decodes and resizes the crop on this thread, which
                // overlaps with the decode thread working on earlier regions.
                let job = try core.makeJob(for: request, isCancelled: isCancelled) { result in
                    store(result, at: index)
                    group.leave()
                }
                core.enqueue(job)
            } catch {
                store(.failure(error), at: index)
                group.leave()
            }
        }
        group.wait()
        return results
    }

    /// Reads one image with the prompt for `task`.
    func recognize(image: CGImage,
                   crop: CGRect? = nil,
                   task: VLTask,
                   maxTokens: Int? = nil,
                   isCancelled: (() -> Bool)? = nil) throws -> String {
        let request = VLRequest(image: image, crop: crop, task: task, maxTokens: maxTokens)
        return try recognize([request], isCancelled: isCancelled)[0].get().text
    }
}

// MARK: - Scheduler

extension VLEngine {

    /// A tokenised region on its way through the engine.
    fileprivate final class Job {
        /// mtmd's input chunks, owned: text before the image, the image, the
        /// prompt after it.
        let chunks: OpaquePointer
        /// The image among `chunks`, which the encoder thread works on.
        let imageChunk: OpaquePointer?
        /// KV cells this region can occupy at most: its input plus the longest
        /// answer it is allowed to give.
        let need: Int
        let limit: Int
        let isCancelled: (() -> Bool)?
        let complete: (Result<VLOutput, Error>) -> Void
        /// The vision encoder's output for `imageChunk`, copied out of mtmd's
        /// scratch buffer — which the next encode overwrites — and dropped
        /// once the language model has read it.
        var embedding: [Float]?

        init(chunks: OpaquePointer, need: Int, limit: Int,
             isCancelled: (() -> Bool)?, complete: @escaping (Result<VLOutput, Error>) -> Void) {
            self.chunks = chunks
            imageChunk = (0..<mtmd_input_chunks_size(chunks))
                .compactMap { mtmd_input_chunks_get(chunks, $0) }
                .first { mtmd_input_chunk_get_type($0) == MTMD_INPUT_CHUNK_TYPE_IMAGE }
            self.need = need
            self.limit = limit
            self.isCancelled = isCancelled
            self.complete = complete
        }

        deinit { mtmd_input_chunks_free(chunks) }
    }

    /// A sequence being decoded.
    fileprivate struct Slot {
        let seq: llama_seq_id
        let job: Job
        var tokens: [llama_token] = []
        /// Bytes per token, so a runaway tail can be cut back off the output.
        var pieceLengths: [Int] = []
        /// Tokens are byte sequences, not characters: a CJK character spans
        /// three bytes and is routinely split across two tokens, so the text is
        /// only decoded once the answer is complete.
        var bytes: [UInt8] = []
        /// Sampled but not yet fed back through the model.
        var pending: llama_token = 0
    }

    /// Owns the llama objects and the two threads that drive them.
    ///
    /// Reading a region has two halves that want different things from the
    /// GPU. The vision encoder turns the crop into embeddings: a few large,
    /// compute-bound matrix products. Generating the answer is hundreds of
    /// tiny steps, each bound by latency, leaving most of the GPU idle. So the
    /// encoder runs on one thread, a region or two ahead, and the language
    /// model decodes on another, and the two overlap instead of taking turns.
    ///
    /// Kept apart from `VLEngine` so the threads can hold it strongly while the
    /// engine's own `deinit` waits for them to finish.
    fileprivate final class Core: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let multimodal: OpaquePointer
        let vocab: OpaquePointer
        let config: VLConfig
        let parallelism: Int
        /// Largest single submission to `llama_decode`.
        let submission: Int32
        private let vocabSize: Int
        private let embeddingWidth: Int
        /// The OTSL cell tokens. A run of them repeating is a table with many
        /// empty or merged cells, not a decoder stuck in a loop.
        private let structuralTokens: Set<llama_token>
        private let marker: String

        // Shared between callers and both threads, under `condition`.
        private let condition = NSCondition()
        /// Tokenised, waiting for the encoder.
        private var waiting: [Job] = []
        /// Encoded, waiting for a sequence.
        private var ready: [Job] = []
        private var stopping = false
        private let exited = DispatchSemaphore(value: 0)

        // Decode thread only.
        private var active: [Slot] = []
        private var freeSequences: [llama_seq_id] = []
        /// KV cells promised to the sequences currently running.
        private var reserved = 0
        /// Cells the scheduler may promise. Lowered when llama.cpp turns a step
        /// down for want of room — the estimate was optimistic — and restored
        /// once the batch drains.
        private var ceiling = 0
        private var piece = [CChar](repeating: 0, count: 256)

        init(model: OpaquePointer, context: OpaquePointer, multimodal: OpaquePointer,
             vocab: OpaquePointer, config: VLConfig, parallelism: Int, submission: Int32) {
            self.model = model
            self.context = context
            self.multimodal = multimodal
            self.vocab = vocab
            self.config = config
            self.parallelism = parallelism
            self.submission = submission
            vocabSize = Int(llama_vocab_n_tokens(vocab))
            structuralTokens = Set(PPDocumentAssembler.otslTokens.compactMap { token -> llama_token? in
                var ids = [llama_token](repeating: 0, count: 4)
                let count = llama_tokenize(vocab, token, Int32(token.utf8.count), &ids, 4, false, true)
                return count == 1 ? ids[0] : nil
            })
            embeddingWidth = Int(llama_model_n_embd_inp(model))
            marker = String(cString: mtmd_get_marker(multimodal) ?? mtmd_default_marker())
        }

        func start() {
            for (name, body) in [("PaddleOCR-VL encode", encodeLoop),
                                 ("PaddleOCR-VL decode", decodeLoop)] {
                let thread = Thread { [self] in
                    body()
                    exited.signal()
                }
                thread.name = name
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }

        /// Stops both threads, waits for them, then frees the model.
        func shutdown() {
            condition.lock()
            stopping = true
            condition.broadcast()
            condition.unlock()
            exited.wait()
            exited.wait()
            mtmd_free(multimodal)
            llama_free(context)
            llama_model_free(model)
        }

        func enqueue(_ job: Job) {
            condition.lock()
            waiting.append(job)
            condition.broadcast()
            condition.unlock()
        }

        // MARK: Tokenising (any thread)

        /// PaddleOCR-VL's chat template, applied by hand.
        ///
        /// The template shipped with the model is custom enough that llama.cpp
        /// refuses it without a Jinja engine, but its shape is simple and fixed,
        /// so building the string directly avoids dragging that dependency in.
        private func prompt(for task: VLTask) -> String {
            "<|begin_of_sentence|>User: \(marker)\(task.prompt)\nAssistant:\n"
        }

        func makeJob(for request: VLRequest, isCancelled: (() -> Bool)?,
                     complete: @escaping (Result<VLOutput, Error>) -> Void) throws -> Job {
            guard let buffer = VLImageBuffer(cgImage: request.image, cropping: request.crop) else {
                throw VLError.imageDecodeFailed
            }
            guard let bitmap = buffer.pixels.withUnsafeBufferPointer({
                mtmd_bitmap_init(UInt32(buffer.width), UInt32(buffer.height), $0.baseAddress)
            }) else {
                throw VLError.imageDecodeFailed
            }
            // Tokenising preprocesses the pixels into the chunk, which keeps its
            // own copy; the bitmap is not needed past this call.
            defer { mtmd_bitmap_free(bitmap) }

            guard let chunks = mtmd_input_chunks_init() else {
                throw VLError.multimodalFailed("无法创建输入块")
            }
            var status: Int32 = 0
            prompt(for: request.task).withCString { text in
                var input = mtmd_input_text(text: text, text_len: strlen(text),
                                            add_special: true, parse_special: true)
                var bitmaps: [OpaquePointer?] = [bitmap]
                status = bitmaps.withUnsafeMutableBufferPointer { buf in
                    mtmd_tokenize(multimodal, chunks, &input, buf.baseAddress, 1)
                }
            }
            guard status == 0 else {
                mtmd_input_chunks_free(chunks)
                throw VLError.tokenizeFailed(status)
            }

            let limit = max(1, request.maxTokens ?? config.maxOutputTokens)
            let input = Int(mtmd_helper_get_n_tokens(chunks))
            return Job(chunks: chunks, need: input + limit, limit: limit,
                       isCancelled: isCancelled, complete: complete)
        }

        // MARK: Encoding (encode thread)

        /// Runs the vision encoder over regions in arrival order, staying at
        /// most a batch's worth ahead of the decoder so encoded regions do not
        /// pile up in memory.
        private func encodeLoop() {
            while true {
                condition.lock()
                while !stopping && (waiting.isEmpty || ready.count >= parallelism) {
                    condition.wait()
                }
                if stopping {
                    let abandoned = waiting
                    waiting.removeAll()
                    condition.unlock()
                    abandoned.forEach { $0.complete(.success(.cancelled)) }
                    return
                }
                let job = waiting.removeFirst()
                condition.unlock()

                if job.isCancelled?() == true {
                    job.complete(.success(.cancelled))
                    continue
                }
                if let image = job.imageChunk {
                    let status = mtmd_encode_chunk(multimodal, image)
                    guard status == 0, let output = mtmd_get_output_embd(multimodal) else {
                        job.complete(.failure(VLError.evalFailed(status)))
                        continue
                    }
                    let count = Int(mtmd_input_chunk_get_n_tokens(image)) * embeddingWidth
                    job.embedding = Array(UnsafeBufferPointer(start: output, count: count))
                }

                condition.lock()
                ready.append(job)
                condition.broadcast()
                condition.unlock()
            }
        }

        // MARK: Decoding (decode thread)

        private func decodeLoop() {
            let memory = llama_get_memory(context)
            llama_memory_clear(memory, true)
            freeSequences = (0..<Int32(parallelism)).reversed().map { llama_seq_id($0) }
            let budget = Int(llama_n_ctx(context))
            ceiling = budget

            var batch = llama_batch_init(Int32(parallelism), 0, 1)
            defer { llama_batch_free(batch) }
            // Positions are left to llama.cpp, which continues each sequence
            // from the last position it holds — exactly what the one-sequence
            // decode did with `llama_batch_get_one`. PaddleOCR-VL uses M-RoPE,
            // whose image positions are not one per token, so working them out
            // here would only be a second, riskier copy of what mtmd already did.
            let positions = batch.pos

            while true {
                condition.lock()
                while ready.isEmpty && active.isEmpty && !stopping { condition.wait() }
                if stopping {
                    let abandoned = ready
                    ready.removeAll()
                    condition.unlock()
                    abandoned.forEach { $0.complete(.success(.cancelled)) }
                    for slot in active { close(slot, ending: .cancelled) }
                    active.removeAll()
                    return
                }
                if active.isEmpty { ceiling = budget }
                // Admit, in arrival order, whatever fits: a free sequence and
                // room in the cache for the longest answer it could give. A
                // region that needs more than the whole budget still runs on
                // its own, as it always did, and fails there if it must.
                var admitting: [Job] = []
                var room = ceiling - reserved
                while let job = ready.first, admitting.count < freeSequences.count {
                    let alone = active.isEmpty && admitting.isEmpty
                    guard alone || job.need <= room else { break }
                    ready.removeFirst()
                    admitting.append(job)
                    room -= job.need
                }
                if !admitting.isEmpty { condition.broadcast() }
                condition.unlock()

                for job in admitting { prefill(job, memory: memory) }
                guard !active.isEmpty else { continue }

                // One step for every live sequence: each contributes the token
                // it sampled last, and gets its next distribution back.
                batch.n_tokens = Int32(active.count)
                for (index, slot) in active.enumerated() {
                    batch.token[index] = slot.pending
                    batch.n_seq_id[index] = 1
                    batch.seq_id[index]![0] = slot.seq
                    batch.logits[index] = 1
                }
                batch.pos = nil
                let status = llama_decode(context, batch)
                batch.pos = positions

                if status == 1, active.count > 1 {
                    // No room for this step after all. Send the newest region
                    // back to be read again from scratch — with the same
                    // result — and stop admitting until something finishes.
                    let evicted = active.removeLast()
                    llama_memory_seq_rm(memory, evicted.seq, -1, -1)
                    freeSequences.append(evicted.seq)
                    reserved -= evicted.job.need
                    ceiling = reserved
                    condition.lock()
                    waiting.insert(evicted.job, at: 0)
                    condition.broadcast()
                    condition.unlock()
                    continue
                }
                guard status == 0 else {
                    for slot in active { close(slot, ending: .decodeFailed) }
                    active.removeAll()
                    continue
                }

                var running: [Slot] = []
                running.reserveCapacity(active.count)
                for (index, var slot) in active.enumerated() {
                    if let ending = advance(&slot, logits: llama_get_logits_ith(context, Int32(index))) {
                        close(slot, ending: ending)
                    } else {
                        running.append(slot)
                    }
                }
                active = running
            }
        }

        /// Feeds a region's image and prompt through the language model and
        /// samples its first token.
        private func prefill(_ job: Job, memory: llama_memory_t?) {
            if job.isCancelled?() == true {
                job.complete(.success(.cancelled))
                return
            }
            let seq = freeSequences.removeLast()
            var nPast: llama_pos = 0
            var status: Int32 = 0
            let count = mtmd_input_chunks_size(job.chunks)
            for index in 0..<count where status == 0 {
                guard let chunk = mtmd_input_chunks_get(job.chunks, index) else { continue }
                if chunk == job.imageChunk, job.embedding != nil {
                    status = job.embedding!.withUnsafeMutableBufferPointer {
                        mtmd_helper_decode_image_chunk(multimodal, context, chunk, $0.baseAddress,
                                                       nPast, seq, submission, &nPast, nil, nil)
                    }
                } else {
                    status = mtmd_helper_eval_chunk_single(multimodal, context, chunk, nPast, seq,
                                                           submission, index == count - 1, &nPast)
                }
            }
            job.embedding = nil
            guard status == 0 else {
                llama_memory_seq_rm(memory, seq, -1, -1)
                freeSequences.append(seq)
                job.complete(.failure(VLError.evalFailed(status)))
                return
            }
            reserved += job.need

            // The logits for the prompt's last token are the newest ones in the
            // context; the next decode call would overwrite them, so the first
            // token is sampled now.
            var slot = Slot(seq: seq, job: job)
            if let ending = advance(&slot, logits: llama_get_logits_ith(context, -1)) {
                close(slot, ending: ending)
            } else {
                active.append(slot)
            }
        }

        /// Picks a sequence's next token and decides whether it goes on.
        ///
        /// Returns nil when the sequence continues, with `slot.pending` holding
        /// the token to feed back; otherwise, why it stopped. The checks run in
        /// the order the one-sequence loop ran them, so a region ends on
        /// exactly the token it used to end on.
        private func advance(_ slot: inout Slot,
                             logits: UnsafeMutablePointer<Float>?) -> VLOutput.Ending? {
            if slot.job.isCancelled?() == true { return .cancelled }
            guard let logits else { return .decodeFailed }

            let best = Self.sample(logits: logits, vocabSize: vocabSize,
                                   produced: slot.tokens, config: config)
            if llama_vocab_is_eog(vocab, best) { return .finished }

            let written = piece.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocab, best, $0.baseAddress, Int32($0.count), 0, false)
            }
            slot.tokens.append(best)
            slot.pieceLengths.append(Int(max(0, written)))
            if written > 0 {
                piece.withUnsafeBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(written)) {
                        slot.bytes.append(contentsOf: UnsafeBufferPointer(start: $0, count: Int(written)))
                    }
                }
            }

            // Greedy decoding on a dense block sometimes falls into a loop and
            // then spends the whole token budget on it — which is what turned
            // the bottom of a page into the same line over and over. Stop at
            // the loop and drop everything but its first pass.
            if let loop = Self.runawayRepeat(in: slot.tokens, ignoring: structuralTokens) {
                let discard = (loop.repeats - 1) * loop.period
                let removedBytes = slot.pieceLengths.suffix(discard).reduce(0, +)
                slot.bytes.removeLast(min(removedBytes, slot.bytes.count))
                return .repetition
            }
            if slot.tokens.count >= slot.job.limit { return .lengthLimit }

            slot.pending = best
            return nil
        }

        /// Frees a sequence's cells and hands its answer back.
        private func close(_ slot: Slot, ending: VLOutput.Ending) {
            llama_memory_seq_rm(llama_get_memory(context), slot.seq, -1, -1)
            freeSequences.append(slot.seq)
            reserved -= slot.job.need
            let text = String(decoding: slot.bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            slot.job.complete(.success(VLOutput(text: text, ending: ending)))
        }

        // MARK: Sampling

        /// Picks the next token.
        ///
        /// PaddleOCR-VL is a transcription model and the reference pipeline runs
        /// it at temperature 0, which is the default here too: with the
        /// reference defaults this is `argmax` and nothing else runs. The three
        /// knobs it exposes — repetition penalty, temperature, top-p — are
        /// implemented because a page that sends the decoder into a loop is the
        /// one case where a plain greedy decode has no way out.
        static func sample(logits: UnsafeMutablePointer<Float>, vocabSize: Int,
                           produced: [llama_token], config: VLConfig) -> llama_token {
            let penalty = Float(config.repetitionPenalty)
            if penalty > 1 {
                // The CTRL formulation: a token already produced is pushed towards
                // zero, whichever side of it the logit is on.
                for token in Set(produced) {
                    let id = Int(token)
                    guard id >= 0, id < vocabSize else { continue }
                    logits[id] = logits[id] > 0 ? logits[id] / penalty : logits[id] * penalty
                }
            }

            guard config.temperature > 0 else {
                // vDSP returns the lowest index among equal maxima, the same
                // tie-break as a strict `>` scan from the front.
                var value: Float = 0
                var index: vDSP_Length = 0
                vDSP_maxvi(logits, 1, &value, &index, vDSP_Length(vocabSize))
                return llama_token(index)
            }

            let temperature = Float(config.temperature)
            var candidates = (0..<vocabSize).map { (id: $0, logit: logits[$0] / temperature) }
            candidates.sort { $0.logit > $1.logit }

            // Softmax over the sorted head is enough: the tail is what top-p is
            // about to discard anyway.
            let maxLogit = candidates[0].logit
            var probabilities = candidates.map { expf($0.logit - maxLogit) }
            let total = probabilities.reduce(0, +)
            guard total > 0 else { return llama_token(candidates[0].id) }
            for index in probabilities.indices { probabilities[index] /= total }

            let topP = Float(min(max(config.topP, 0.01), 1))
            var cumulative: Float = 0
            var cutoff = probabilities.count
            for index in probabilities.indices {
                cumulative += probabilities[index]
                if cumulative >= topP { cutoff = index + 1; break }
            }

            let roll = Float.random(in: 0..<max(cumulative, .leastNonzeroMagnitude))
            var running: Float = 0
            for index in 0..<cutoff {
                running += probabilities[index]
                if running >= roll { return llama_token(candidates[index].id) }
            }
            return llama_token(candidates[0].id)
        }

        /// Detects a degenerate loop at the tail: the last `period` tokens
        /// repeated `repeats` times over.
        ///
        /// Short cycles have to repeat more often before they count — a table
        /// row of empty cells is a handful of tokens repeating legitimately,
        /// while a stuck decoder repeats until the budget runs out. Nothing
        /// shorter than four passes is ever treated as a loop, so ordinary
        /// repetition survives.
        ///
        /// A cycle made only of `ignoring` tokens never counts: in a sparse
        /// table eight empty cells in a row are just eight empty cells, and
        /// treating them as a loop cut real tables off mid-row.
        static func runawayRepeat(in tokens: [llama_token],
                                  ignoring structural: Set<llama_token> = []) -> (period: Int, repeats: Int)? {
            for period in 1...16 {
                let repeats = period >= 5 ? 4 : 8
                guard tokens.count >= period * repeats else { continue }
                if !structural.isEmpty, tokens.suffix(period).allSatisfy(structural.contains) { continue }
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
}
