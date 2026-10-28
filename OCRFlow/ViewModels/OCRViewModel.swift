import Foundation
import AppKit
import Vision
import Combine
import UniformTypeIdentifiers
import OnnxRuntimeBindings

// MARK: - OCR Engine

enum OCREngine: String, CaseIterable, Identifiable, Codable {
    /// 智能分层: each region of a page goes to the reader that suits it. See
    /// `LayeredPipeline`.
    case auto           = "auto"
    case visionFast     = "vision_fast"
    case visionAccurate = "vision_accurate"
    case paddleOCR      = "paddle_ocr"
    case paddleVL       = "paddle_vl"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:           return String(localized: "Smart Layering (recommended)")
        case .visionFast:     return String(localized: "Apple Vision · Fast")
        case .visionAccurate: return String(localized: "Apple Vision · Accurate")
        case .paddleOCR:      return "PaddleOCR · PP-OCRv6"
        case .paddleVL:       return "PaddleOCR-VL · 1.6"
        }
    }

    var hint: String {
        switch self {
        case .auto:
            return String(localized: "Native PDF text is extracted directly. Body text goes to PP-OCRv6; tables, formulas, charts, seals and low-confidence regions go to PaddleOCR-VL")
        case .visionFast:     return String(localized: "Fast, good for quick batch processing")
        case .visionAccurate: return String(localized: "Better results, a little slower")
        case .paddleOCR:      return String(localized: "PP-OCRv6 model. One model covers 50 languages and outputs line boxes with confidence")
        case .paddleVL:       return String(localized: "0.9B vision-language model. Layout analysis plus block-by-block reading, outputs Markdown (slower, requires model download)")
        }
    }

    /// The short name the file list and the result pane use.
    var shortLabel: String {
        switch self {
        case .auto:           return String(localized: "Smart Layering")
        case .visionFast:     return String(localized: "Vision Fast")
        case .visionAccurate: return String(localized: "Vision Accurate")
        case .paddleOCR:      return "PP-OCRv6"
        case .paddleVL:       return "PaddleOCR-VL"
        }
    }

    /// Engines whose models live on the GPU and serve many regions at once:
    /// two files in flight keep them fed, more only queue.
    var prefersFewFilesInFlight: Bool { self == .auto || self == .paddleVL }

    /// Vision picks languages from a list; the PaddleOCR engines pick them by
    /// model file, and PaddleOCR-VL is multilingual with no setting at all.
    var usesVisionLanguages: Bool { self == .visionFast || self == .visionAccurate }
}

// MARK: - Persisted settings

/// Everything the app remembers between launches.
///
/// The file list and the run-time progress deliberately stay out: a session's
/// queue is not a setting. Keeping the defaults here rather than spread across
/// the view model's property initialisers means "restore defaults" and "what a
/// fresh install looks like" cannot drift apart.
struct OCRSettings: Codable, Equatable {
    var engine: OCREngine = .auto
    var recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]
    var maxConcurrentTasks: Int = OCRViewModel.defaultConcurrency
    var showTextBoxes = true
    var paddle: PPOCRConfig = .default
    var vl: VLConfig = .default
    var layered: LayeredConfig = .default
    var mergeLineBreaks = false
    var removeEmptyLines = false
    var trimWhitespace = true
    var removeHyphenBreaks = false
    var autoStartOnAdd = false
    var skipCompleted = true
    var exportSeparator: OCRViewModel.ExportSeparator = .emptyLine
    var exportIncludeFilename = true
    var exportFormat: OCRViewModel.ExportFormat = .markdown
    var exportLayout: OCRViewModel.ExportLayout = .combined
    var renderFigures = true
    var renderTables = true
    var exportFigures = true
    var dropPageFurniture = true
    /// `rawName` of every auxiliary region kept in the document. Stored as
    /// strings so a label added to the model later cannot make the file
    /// unreadable.
    var keptAuxiliary: [String] = []
    var useDocUnwarping = false
    var watchEnabled = false
    var watchFolderPath: String?
    var watchOutputPath: String?
}

extension OCRSettings {
    /// Decodes field by field, falling back to the default for anything missing
    /// or no longer readable. A settings file written by an older build then
    /// loses only the fields that actually changed shape, instead of throwing
    /// and resetting everything the user had tuned.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = OCRSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? `default`
        }
        engine = value(.engine, fallback.engine)
        recognitionLanguages = value(.recognitionLanguages, fallback.recognitionLanguages)
        maxConcurrentTasks = value(.maxConcurrentTasks, fallback.maxConcurrentTasks)
        showTextBoxes = value(.showTextBoxes, fallback.showTextBoxes)
        paddle = value(.paddle, fallback.paddle)
        vl = value(.vl, fallback.vl)
        layered = value(.layered, fallback.layered)
        mergeLineBreaks = value(.mergeLineBreaks, fallback.mergeLineBreaks)
        removeEmptyLines = value(.removeEmptyLines, fallback.removeEmptyLines)
        trimWhitespace = value(.trimWhitespace, fallback.trimWhitespace)
        removeHyphenBreaks = value(.removeHyphenBreaks, fallback.removeHyphenBreaks)
        autoStartOnAdd = value(.autoStartOnAdd, fallback.autoStartOnAdd)
        skipCompleted = value(.skipCompleted, fallback.skipCompleted)
        exportSeparator = value(.exportSeparator, fallback.exportSeparator)
        exportIncludeFilename = value(.exportIncludeFilename, fallback.exportIncludeFilename)
        exportFormat = value(.exportFormat, fallback.exportFormat)
        exportLayout = value(.exportLayout, fallback.exportLayout)
        renderFigures = value(.renderFigures, fallback.renderFigures)
        renderTables = value(.renderTables, fallback.renderTables)
        exportFigures = value(.exportFigures, fallback.exportFigures)
        // The preference used to live inside the PaddleOCR-VL settings, back
        // when only that engine produced layout blocks. A file written by such
        // a build carries the user's choice there.
        dropPageFurniture = (try? container.decode(Bool.self, forKey: .dropPageFurniture))
            ?? vl.dropPageFurniture
        // Before the switches were split apart there was one of them, and it
        // covered the three that repeat on every page.
        useDocUnwarping = value(.useDocUnwarping, fallback.useDocUnwarping)
        watchEnabled = value(.watchEnabled, fallback.watchEnabled)
        watchFolderPath = try? container.decodeIfPresent(String.self, forKey: .watchFolderPath)
        watchOutputPath = try? container.decodeIfPresent(String.self, forKey: .watchOutputPath)
        keptAuxiliary = (try? container.decode([String].self, forKey: .keptAuxiliary))
            ?? (dropPageFurniture ? PPLayoutLabel.auxiliary
                    .filter { !$0.isPageFurniture }.map(\.rawName)
                : PPLayoutLabel.auxiliary.map(\.rawName))
    }
}

@MainActor
final class OCRViewModel: ObservableObject {

    // MARK: - Published state

    @Published var items: [ImageItem] = []
    @Published var selectedIDs: Set<UUID> = []
    /// Whether the window is browsing documents or working through what was
    /// flagged for review.
    @Published var mode: WorkspaceMode = .workspace
    /// The flagged item the review pane is on.
    @Published var reviewFocus: ReviewEntry.Key?
    /// A page and region the document pane should turn to, set when leaving
    /// review for "在文档中查看". The pane clears it once it has moved.
    @Published var documentFocus: DocumentFocus?
    /// What the sidebar is searching for. The document pane reads it too, to
    /// open a file found by its contents at the place it says that.
    @Published var searchQuery = ""
    @Published var isProcessing = false
    /// Set between pressing 停止 and the last in-flight image actually letting
    /// go. A run cannot be restarted in that window: the worker still holds the
    /// cancellation token, and re-arming it would let a half-finished page be
    /// written out as a finished one.
    @Published private(set) var isStopping = false
    @Published var totalProgress: Double = 0        // 0.0 – 1.0
    @Published var recognitionLanguages: [String] = OCRSettings().recognitionLanguages {
        didSet { persistSettings() }
    }
    @Published var ocrEngine: OCREngine = OCRSettings().engine {
        didSet { persistSettings() }
    }
    /// How many images `startProcessing` runs at once. Decoding and Vision
    /// recognition genuinely parallelise across cores; PaddleOCR's own engine
    /// still finishes one recognition before starting the next regardless of
    /// this value (see `processConcurrently`).
    @Published var maxConcurrentTasks: Int = OCRViewModel.defaultConcurrency {
        didSet { persistSettings() }
    }

    /// Nonisolated so `OCRSettings` can use it as a default without hopping to
    /// the main actor; it only reads the process's core count.
    nonisolated static var defaultConcurrency: Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    // MARK: - PaddleOCR settings
    @Published var paddleConfig: PPOCRConfig = .default {
        didSet {
            // Swapping the model files or the backend invalidates the loaded
            // sessions; the tuning knobs are read per image and do not.
            if let engine = paddleEngine, !engine.matchesModelConfiguration(paddleConfig) {
                paddleEngine = nil
            }
            persistSettings()
        }
    }
    /// Draw PaddleOCR's detected text boxes over the preview.
    @Published var showTextBoxes = true {
        didSet { persistSettings() }
    }

    // MARK: - PaddleOCR-VL settings
    @Published var vlConfig: VLConfig = .default {
        didSet {
            if let engine = vlEngine, !engine.matchesModelConfiguration(vlConfig) {
                vlEngine = nil
            }
            persistSettings()
        }
    }

    // MARK: - 智能分层 settings
    @Published var layeredConfig: LayeredConfig = .default {
        didSet { persistSettings() }
    }

    /// Loaded VLM weights, kept alive across images. Held separately from the
    /// PP-OCR engine because the two can be swapped independently.
    private var vlEngine: VLEngine?
    /// The layout stage, loaded alongside the VLM.
    private var vlLayoutSession: PPSession?
    private var vlLayoutEnv: ORTEnv?

    /// Loaded ONNX sessions, kept alive across images.
    private var paddleEngine: PPOCREngine?
    /// UVDoc, loaded the first time a page has to be flattened.
    private var docUnwarper: PPDocUnwarper?
    private var docUnwarperEnv: ORTEnv?
    /// Read from the OCR worker thread to honour the Stop button mid-image.
    private let cancellation = PPCancellationToken()

    /// Installs the models that are not bundled. Its changes are republished
    /// below so the settings sheet re-reads what is on disk after a download.
    let modelDownloader = PPModelDownloader()
    private var downloaderObserver: AnyCancellable?

    private var terminationObserver: NSObjectProtocol?

    /// The queue and its results on disk, and the recognition cache.
    let store = ResultStore()
    /// False until the queue saved by the last session has been read back;
    /// the list shows nothing actionable before then.
    @Published private(set) var isRestoringQueue = true

    /// The crash log the last session left, when it ended in a crash. The
    /// window offers to report it once, then it is cleared.
    @Published var crashLogFromLastSession: URL?
    private lazy var sentinel = LaunchSentinel(directory: store.directory)

    init() {
        crashLogFromLastSession = sentinel.begin()
        restoreSettings()
        validateModelSelections()
        // Write the settings back in their normalised form. Without this a file
        // that was partial, or written by an older build, stays that way on disk
        // until the user happens to change something.
        persistSettings()

        downloaderObserver = modelDownloader.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // A model the user just deleted may be the one currently selected.
            // The publisher fires before the store's own state settles, so the
            // check runs on the next turn of the main actor.
            Task { @MainActor in self?.validateModelSelections() }
        }
        // llama.cpp tears its Metal device down in a static destructor and
        // asserts if a model is still loaded at that point, which crashes the
        // app on quit. Releasing the engine while the run loop is still alive
        // keeps the teardown in the right order.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.saveQueue(self.items)
                self.releaseVLEngine()
                self.sentinel.end()
            }
        }
        restoreQueue()
    }

    /// Reads back the list the last session left: every file, its status and
    /// its result. A file that was being read when the app went away comes
    /// back as 待处理, and 开始识别 carries on from there.
    private func restoreQueue() {
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let restored = store.load()
            await MainActor.run {
                // Anything added while the queue was loading goes after it.
                let added = self.items
                let restoredURLs = Set(restored.map(\.url))
                var all = restored
                all.append(contentsOf: added.filter { !restoredURLs.contains($0.url) })
                self.items = all
                self.settleEquivalentReadings()
                self.rebuildDocuments()
                if self.selectedIDs.isEmpty, let first = all.first { self.selectedIDs = [first.id] }
                self.isRestoringQueue = false
                self.recalcProgress()
                self.updateWatcher()
                store.pruneResults(keeping: Set(all.map(\.id)))
                store.prunePartials(keeping: Set(all.compactMap(\.resume?.key)))
                self.loadThumbnails(for: restored.map(\.id))
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Settings persistence

    private static let settingsKey = "OCRFlow.settings"

    /// Set while the stored values are being written back into the published
    /// properties, so each one's `didSet` does not save what was just loaded.
    private var isRestoringSettings = false

    private var settingsSnapshot: OCRSettings {
        OCRSettings(engine: ocrEngine,
                    recognitionLanguages: recognitionLanguages,
                    maxConcurrentTasks: maxConcurrentTasks,
                    showTextBoxes: showTextBoxes,
                    paddle: paddleConfig,
                    vl: vlConfig,
                    layered: layeredConfig,
                    mergeLineBreaks: mergeLineBreaks,
                    removeEmptyLines: removeEmptyLines,
                    trimWhitespace: trimWhitespace,
                    removeHyphenBreaks: removeHyphenBreaks,
                    autoStartOnAdd: autoStartOnAdd,
                    skipCompleted: skipCompleted,
                    exportSeparator: exportSeparator,
                    exportIncludeFilename: exportIncludeFilename,
                    exportFormat: exportFormat,
                    exportLayout: exportLayout,
                    renderFigures: renderFigures,
                    renderTables: renderTables,
                    exportFigures: exportFigures,
                    dropPageFurniture: dropPageFurniture,
                    keptAuxiliary: keptAuxiliary.map(\.rawName),
                    useDocUnwarping: useDocUnwarping,
                    watchEnabled: watchEnabled,
                    watchFolderPath: watchFolder?.path,
                    watchOutputPath: watchOutputFolder?.path)
    }

    private func persistSettings() {
        guard !isRestoringSettings else { return }
        guard let data = try? JSONEncoder().encode(settingsSnapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func restoreSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let stored = try? JSONDecoder().decode(OCRSettings.self, from: data) else { return }
        apply(stored)
    }

    private func apply(_ settings: OCRSettings) {
        isRestoringSettings = true
        defer { isRestoringSettings = false }

        ocrEngine = settings.engine
        // An empty list would leave Vision with nothing to look for.
        recognitionLanguages = settings.recognitionLanguages.isEmpty
            ? OCRSettings().recognitionLanguages
            : settings.recognitionLanguages
        maxConcurrentTasks = min(8, max(1, settings.maxConcurrentTasks))
        showTextBoxes = settings.showTextBoxes
        paddleConfig = settings.paddle
        vlConfig = settings.vl
        layeredConfig = settings.layered
        mergeLineBreaks = settings.mergeLineBreaks
        removeEmptyLines = settings.removeEmptyLines
        trimWhitespace = settings.trimWhitespace
        removeHyphenBreaks = settings.removeHyphenBreaks
        autoStartOnAdd = settings.autoStartOnAdd
        skipCompleted = settings.skipCompleted
        exportSeparator = settings.exportSeparator
        exportIncludeFilename = settings.exportIncludeFilename
        exportFormat = settings.exportFormat
        exportLayout = settings.exportLayout
        renderFigures = settings.renderFigures
        renderTables = settings.renderTables
        exportFigures = settings.exportFigures
        dropPageFurniture = settings.dropPageFurniture
        keptAuxiliary = Set(settings.keptAuxiliary.compactMap(PPLayoutLabel.init(rawName:)))
        useDocUnwarping = settings.useDocUnwarping
        watchFolder = settings.watchFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        watchOutputFolder = settings.watchOutputPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        watchEnabled = settings.watchEnabled
    }

    func resetAllSettings() {
        apply(OCRSettings())
        validateModelSelections()
        persistSettings()
        updateWatcher()
    }

    /// Drops any selection whose model files are not on disk — deleted from the
    /// model manager, or restored from settings written on another machine.
    /// Without this the app would keep a model selected that it cannot load and
    /// fail on every image, instead of quietly falling back to one that works.
    func validateModelSelections() {
        if !PPModelStore.isInstalled(paddleConfig.tier) {
            paddleConfig.tier = PPOCRConfig.default.tier
            paddleConfig.applyDetectionDefaults()
        }
        if let fileName = paddleConfig.recognizer.customFileName,
           !PPModelStore.isDownloaded(fileName) {
            paddleConfig.recognizer = .builtin
        }
        if !VLModelStore.isInstalled(vlConfig.variant),
           let installed = VLModelVariant.allCases.first(where: VLModelStore.isInstalled) {
            vlConfig.variant = installed
        }
        if ocrEngine == .paddleVL, !VLModelStore.isReady(for: vlConfig) {
            ocrEngine = .paddleOCR
        }
        // Reading order from the layout model needs the layout model. Falling
        // back to the geometric estimate beats reading a page in detection
        // order, which on a multi-column page is not an order at all.
        if paddleConfig.readingOrder.needsLayoutModel, !VLModelStore.isLayoutModelInstalled {
            paddleConfig.readingOrder = .columns
        }
    }

    /// Drops the VLM and its layout session, freeing a gigabyte or more.
    func releaseVLEngine() {
        vlEngine = nil
        vlLayoutSession = nil
        vlLayoutEnv = nil
    }

    /// Switching tier also restores that tier's reference detection thresholds:
    /// the values differ per tier, so a threshold tuned on `tiny` would quietly
    /// mis-tune `medium`.
    func selectTier(_ tier: PPModelTier) {
        guard paddleConfig.tier != tier else { return }
        paddleConfig.tier = tier
        paddleConfig.applyDetectionDefaults()
    }

    func selectRecognizer(_ recognizer: PPRecognizerChoice) {
        guard paddleConfig.recognizer != recognizer else { return }
        paddleConfig.recognizer = recognizer
    }

    /// Resets the tuning knobs but keeps the chosen models and backend, which
    /// is what "restore defaults" means next to a set of sliders.
    func resetPaddleTuning() {
        var reset = PPOCRConfig.default
        reset.tier = paddleConfig.tier
        reset.recognizer = paddleConfig.recognizer
        reset.computeUnit = paddleConfig.computeUnit
        reset.threadCount = paddleConfig.threadCount
        reset.applyDetectionDefaults()
        paddleConfig = reset
    }

    // MARK: - Text post-processing settings
    /// 合并换行为空格（"不换行"模式）
    @Published var mergeLineBreaks = false { didSet { persistSettings() } }
    /// 去除连续空行，只保留单个空行
    @Published var removeEmptyLines = false { didSet { persistSettings() } }
    /// 去除每行首尾多余空格
    @Published var trimWhitespace = true { didSet { persistSettings() } }
    /// 自动去除行内连字符换行（如 "exam-\nple" → "example"）
    @Published var removeHyphenBreaks = false { didSet { persistSettings() } }

    // MARK: - Behavior settings
    /// 添加文件后自动开始识别
    @Published var autoStartOnAdd = false { didSet { persistSettings() } }
    /// 重新处理时跳过已完成的文件
    @Published var skipCompleted = true { didSet { persistSettings() } }

    // MARK: - Export settings
    enum ExportSeparator: String, CaseIterable, Identifiable, Codable {
        case emptyLine, divider, pageBreak, none
        var id: String { rawValue }
        /// The raw value is what settings store; this is what the picker shows.
        var label: String {
            switch self {
            case .emptyLine:  return String(localized: "Blank line")
            case .divider:    return String(localized: "Divider")
            case .pageBreak:  return String(localized: "Page break")
            case .none:       return String(localized: "None")
            }
        }
        var separator: String {
            switch self {
            case .emptyLine:  return "\n\n"
            case .divider:    return "\n\n---\n\n"
            case .pageBreak:  return "\n\u{0C}\n"
            case .none:       return "\n"
            }
        }
    }
    @Published var exportSeparator: ExportSeparator = .emptyLine { didSet { persistSettings() } }
    /// 导出时包含文件名标题
    @Published var exportIncludeFilename = true { didSet { persistSettings() } }

    /// What an export writes.
    enum ExportFormat: String, CaseIterable, Identifiable, Codable {
        case markdown
        case plainText
        /// Boxes, text and confidences — the same material the results pane
        /// shows, in the shape another program can read. The engines produce a
        /// structured page now, and a `.txt` throws all of it away.
        case json
        /// The source pages with the text laid invisibly over them, so Preview,
        /// Spotlight and every other reader can search and copy it.
        case searchablePDF
        /// The recognised tables alone, one sheet each, merged cells kept.
        case excel

        var id: String { rawValue }

        var label: String {
            switch self {
            case .markdown:      return "Markdown"
            case .plainText:     return String(localized: "Plain Text")
            case .json:          return String(localized: "JSON (with coordinates and confidence)")
            case .searchablePDF: return String(localized: "Searchable PDF")
            case .excel:         return String(localized: "Excel (tables only)")
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown:      return "md"
            case .plainText:     return "txt"
            case .json:          return "json"
            case .searchablePDF: return "pdf"
            case .excel:         return "xlsx"
            }
        }
    }

    /// One file, or one file per image.
    enum ExportLayout: String, CaseIterable, Identifiable, Codable {
        case combined
        case separate

        var id: String { rawValue }

        var label: String {
            switch self {
            case .combined: return String(localized: "Combine into one file")
            case .separate: return String(localized: "Export each file separately")
            }
        }
    }

    @Published var exportFormat: ExportFormat = .markdown { didSet { persistSettings() } }
    @Published var exportLayout: ExportLayout = .combined { didSet { persistSettings() } }

    // MARK: - Result rendering settings
    /// Draw the figure and chart regions of the page in the Markdown pane,
    /// cropped from the source image, instead of a bare placeholder.
    @Published var renderFigures = true { didSet { persistSettings() } }
    /// Draw recognised tables as a grid rather than as the HTML the model wrote.
    @Published var renderTables = true { didSet { persistSettings() } }
    /// Write the figures out next to an exported Markdown file and point the
    /// document at them.
    @Published var exportFigures = true { didSet { persistSettings() } }
    /// Leave running headers, footers and page numbers out of the document.
    ///
    /// This is a decision about the *document*, not about the recognition:
    /// those regions are always read and always drawn in the preview, so
    /// flipping this rebuilds what is already on screen instead of asking for
    /// another pass over the file.
    @Published var dropPageFurniture = true {
        didSet {
            guard oldValue != dropPageFurniture else { return }
            persistSettings()
            rebuildDocuments()
        }
    }

    /// Flatten a photographed page before reading it — PaddleOCR's
    /// 图片扭曲矫正. Off by default, as upstream: a scan has nothing to flatten,
    /// and the model would only resample it.
    @Published var useDocUnwarping = false {
        didSet {
            guard oldValue != useDocUnwarping else { return }
            if !useDocUnwarping { docUnwarper = nil; docUnwarperEnv = nil }
            persistSettings()
        }
    }

    /// Which auxiliary regions stay in the document. Everything not in here is
    /// filtered out, which is how PaddleOCR's own 辅助内容解析 switches read:
    /// off means "the model found it and left it out".
    @Published var keptAuxiliary: Set<PPLayoutLabel> = [] {
        didSet {
            guard oldValue != keptAuxiliary else { return }
            persistSettings()
            rebuildDocuments()
        }
    }

    /// The regions left out of the assembled document.
    var droppedLabels: Set<PPLayoutLabel> {
        Set(PPLayoutLabel.auxiliary).subtracting(keptAuxiliary)
    }

    func setAuxiliary(_ label: PPLayoutLabel, kept: Bool) {
        if kept { keptAuxiliary.insert(label) } else { keptAuxiliary.remove(label) }
    }

    /// One page of the document in pieces that remember which region each
    /// came from, for the rendered view. Falls back to one nameless piece for
    /// a page with no regions behind it.
    func documentFragments(for item: ImageItem, page index: Int) -> [PPDocumentAssembler.Fragment] {
        guard item.pages.indices.contains(index) else {
            return [PPDocumentAssembler.Fragment(source: nil, markdown: item.markdown)]
        }
        let page = item.pages[index]
        guard page.derivesFromBlocks else {
            let text = page.rawMarkdown.isEmpty ? page.rawText : page.rawMarkdown
            return [PPDocumentAssembler.Fragment(source: nil, markdown: text)]
        }
        return PPDocumentAssembler.fragments(from: page.blocks,
                                             dropping: droppedLabels,
                                             source: page.blockSource,
                                             inferHeadingLevels: vlConfig.inferHeadingLevels)
    }

    /// One page's text, assembled and post-processed the way the whole
    /// document is.
    func pageText(for item: ImageItem, page index: Int) -> (text: String, markdown: String) {
        guard item.pages.indices.contains(index) else { return (item.ocrText, item.markdown) }
        let assembled = item.pages[index].assembled(dropping: droppedLabels,
                                                    inferHeadingLevels: vlConfig.inferHeadingLevels)
        return (postProcess(assembled.text), assembled.markdown)
    }

    /// Replaces what was read out of one region.
    ///
    /// The model gets a word wrong now and then, and the alternative to fixing
    /// it here is fixing it in the exported file — where the correction is lost
    /// the next time the file is exported. Editing the region itself means the
    /// document, the plain text and every future export all carry it.
    ///
    /// The recognised text is kept beside the correction, so the region can
    /// show what changed and a correction undone back to it stops counting as
    /// one.
    func correctBlock(itemID: UUID, page: Int, blockIndex: Int, text: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].pages.indices.contains(page),
              items[index].pages[page].blocks.indices.contains(blockIndex) else { return }
        var block = items[index].pages[page].blocks[blockIndex]
        guard block.text != text else { return }
        let original = block.recognisedText ?? block.text
        block.recognisedText = text == original ? nil : original
        block.text = text
        // A person has looked at it now; whatever the check flagged is settled.
        block.review = nil
        block.alternative = nil
        items[index].pages[page].blocks[blockIndex] = block
        rebuildDocument(at: index)
        store.save(items[index])
    }

    /// Whether a region of this result can be read again with PaddleOCR-VL.
    func canReread(_ item: ImageItem) -> Bool {
        item.status == .completed && VLModelStore.isInstalled(vlConfig.variant)
    }

    /// Reads one region again with PaddleOCR-VL — the second opinion the
    /// layered pipeline asks for on its own when PP-OCR is unsure, asked for
    /// by hand.
    func rereadBlock(itemID: UUID, page: Int, blockIndex: Int) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].pages.indices.contains(page),
              items[index].pages[page].blocks.indices.contains(blockIndex) else { return }
        let item = items[index]
        let block = item.pages[page].blocks[blockIndex]
        if block.isCorrected {
            let alert = NSAlert()
            alert.messageText = String(localized: "This region has manual edits")
            alert.informativeText = String(localized: "Rereading with PaddleOCR-VL will replace the edited text.")
            alert.addButton(withTitle: String(localized: "Reread"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let task = block.label.vlTask ?? .ocr
        let config = vlConfig
        let pageSize = item.pages[page].size
        // Shown under the region while the model works.
        updateBlock(itemID: itemID, page: page, blockIndex: blockIndex) { $0.review = .rereading }

        Task {
            do {
                let engine = try await loadVLEngine(for: config)
                guard let image = await PagePreviews.image(for: item, page: page)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw OCRError.imageLoadFailed }
                // The preview and the recognised page are the same size; if a
                // file was replaced on disk since, the box is scaled across.
                let sx = CGFloat(image.width) / max(pageSize.width, 1)
                let sy = CGFloat(image.height) / max(pageSize.height, 1)
                let rect = block.rect.applying(CGAffineTransform(scaleX: sx, y: sy))
                let crop = PPLayoutPostProcess.expanded(rect, ratio: config.cropUnclipRatio,
                                                        within: CGSize(width: image.width, height: image.height))
                // Asked for by a person, so given the larger budget the
                // pipeline only reaches for on a second attempt.
                let limit = config.maxOutputTokens * RegionReader.retryBudgetFactor
                let output = try await Task.detached(priority: .userInitiated) {
                    try engine.recognize([VLRequest(image: image, crop: crop, task: task,
                                                    maxTokens: limit)])[0].get()
                }.value
                let previous = AlternativeReading(source: block.source ?? item.pages[page].blockSource,
                                                  text: block.text, note: .beforeReread)
                updateBlock(itemID: itemID, page: page, blockIndex: blockIndex) { block in
                    block.review = nil
                    guard !output.text.isEmpty else {
                        block.review = .rereadReadNothing
                        return
                    }
                    let text = task == .table
                        ? (PPDocumentAssembler.htmlTable(fromOTSL: output.text) ?? output.text) : output.text
                    block.text = text
                    block.source = .visionLanguageModel
                    block.recognisedText = nil
                    block.routing = .rereadOnRequest
                    switch output.ending {
                    case .lengthLimit:  block.review = .outputLimit(tokens: limit)
                    case .repetition:   block.review = .repetition
                    case .decodeFailed: block.review = .interrupted
                    case .finished, .cancelled: break
                    }
                    // The same answer twice settles it — the same words with
                    // the lines broken elsewhere included; a different one is
                    // a choice for the person who asked.
                    let changed = !AlternativeReading.isEquivalent(previous.text, text)
                    block.alternative = changed && !previous.text.isEmpty ? previous : nil
                    if changed, !previous.text.isEmpty, block.review == nil {
                        block.review = .rereadDiffers
                    }
                }
            } catch {
                updateBlock(itemID: itemID, page: page, blockIndex: blockIndex) {
                    $0.review = .rereadFailed(error: error.localizedDescription)
                }
            }
        }
    }

    private func updateBlock(itemID: UUID, page: Int, blockIndex: Int,
                             _ change: (inout PPLayoutBlock) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].pages.indices.contains(page),
              items[index].pages[page].blocks.indices.contains(blockIndex) else { return }
        change(&items[index].pages[page].blocks[blockIndex])
        rebuildDocument(at: index)
        store.save(items[index])
    }

    /// One page of one file.
    struct PageRef: Hashable {
        let itemID: UUID
        let page: Int
    }

    /// Pages being read again on their own right now.
    @Published private(set) var rereadingPages: Set<PageRef> = []

    /// Whether one page of this result can be read again by itself. Not
    /// while a run is going: the page would compete with it for the engines,
    /// and a run that reaches this file would replace the page anyway.
    func canRereadPage(_ item: ImageItem) -> Bool {
        item.status == .completed && !isProcessing && !isStopping
    }

    /// Reads one page of a finished file again and puts it in place of the
    /// old one; every other page, corrections included, stays as it is.
    ///
    /// The page is read with the engine the rest of the file was, so the
    /// document does not end up half one engine and half another; the other
    /// settings are the current ones, which is the point of asking — a page
    /// read badly with one set of settings is read again with better ones.
    ///
    /// The old page's regions are not offered as alternatives, the way
    /// rereading one region is: a page read again comes back with its own
    /// regions, and there is no reliable way to pair them with the old ones.
    func rereadPage(itemID: UUID, page: Int) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              canRereadPage(items[index]), items[index].pages.indices.contains(page) else { return }
        let item = items[index]
        let ref = PageRef(itemID: itemID, page: page)
        guard !rereadingPages.contains(ref) else { return }
        if item.pages[page].blocks.contains(where: \.isCorrected) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Page \(page + 1) has manual edits")
            alert.informativeText = String(localized: "Recognizing this page again replaces these edits with the new result. Other pages are not affected.")
            alert.addButton(withTitle: String(localized: "Recognize Again"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var settings = currentRecognitionSettings()
        if let engine = item.engine { settings.engine = engine }
        let url = item.url
        rereadingPages.insert(ref)

        Task {
            defer { rereadingPages.remove(ref) }
            do {
                let engines = try await loadEngines(for: settings)
                let result = try await Task.detached(priority: .userInitiated) {
                    try DocumentRecognizer.recognize(page: page, of: url, settings: settings, engines: engines,
                                                     isCancelled: { false }, progress: nil)
                }.value
                // The file may have been removed, or read again as a whole,
                // while this page was being read.
                guard let i = items.firstIndex(where: { $0.id == itemID }), items[i].status == .completed,
                      items[i].pages.indices.contains(page) else { return }
                items[i].pages[page] = result
                rebuildDocument(at: i)
                store.save(items[i])
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Recognizing page \(page + 1) again failed")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: - Review

    /// Everything flagged for a person to look at, file by file, page by page,
    /// in reading order — the queue the review mode works through.
    var reviewEntries: [ReviewEntry] {
        items.filter { $0.status == .completed }.flatMap { item in
            item.pages.enumerated().flatMap { pageIndex, page in
                let pageNotes = page.notes.filter { $0.severity == .warning }.map { note in
                    ReviewEntry(itemID: item.id, fileName: item.fileName, page: pageIndex,
                                origin: .note(note), reason: note.reason)
                }
                let regions = page.blocks.indices
                    .filter { page.blocks[$0].review != nil }
                    .sorted { page.blocks[$0].readingOrder < page.blocks[$1].readingOrder }
                    .compactMap { index in
                        page.blocks[index].review.map {
                            ReviewEntry(itemID: item.id, fileName: item.fileName, page: pageIndex,
                                        origin: .region(index), reason: $0)
                        }
                    }
                return pageNotes + regions
            }
        }
    }

    /// Settles one flagged item without changing any text: the region, or the
    /// page note, has been looked at and is fine as it is.
    func resolveReview(_ entry: ReviewEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.itemID }),
              items[index].pages.indices.contains(entry.page) else { return }
        switch entry.origin {
        case let .region(block):
            guard items[index].pages[entry.page].blocks.indices.contains(block) else { return }
            items[index].pages[entry.page].blocks[block].review = nil
            items[index].pages[entry.page].blocks[block].alternative = nil
        case let .note(note):
            items[index].pages[entry.page].notes.removeAll { $0 == note }
        }
        store.save(items[index])
    }

    /// Clears every flag that asks a person to choose between two readings
    /// that say the same thing — left by earlier builds, which compared them
    /// character for character and took a moved line break for a difference.
    private func settleEquivalentReadings() {
        for index in items.indices {
            var changed = false
            for page in items[index].pages.indices {
                for block in items[index].pages[page].blocks.indices {
                    let region = items[index].pages[page].blocks[block]
                    guard let alternative = region.alternative,
                          AlternativeReading.isEquivalent(alternative.text, region.text) else { continue }
                    items[index].pages[page].blocks[block].alternative = nil
                    items[index].pages[page].blocks[block].review = nil
                    changed = true
                }
            }
            if changed { store.save(items[index]) }
        }
    }

    /// Settles a flagged region with the text a person chose.
    ///
    /// Picking one of the two readings as it stands takes that reader's word
    /// for it — the region now says who read it, and nothing counts as
    /// corrected. Anything else typed in is a correction, kept beside what was
    /// recognised the way `correctBlock` keeps it.
    func settleRegion(itemID: UUID, page: Int, blockIndex: Int, text: String, chosenSource: PPTextSource?) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].pages.indices.contains(page),
              items[index].pages[page].blocks.indices.contains(blockIndex) else { return }
        var block = items[index].pages[page].blocks[blockIndex]
        if let chosenSource {
            block.text = text
            block.source = chosenSource
        } else if block.text != text {
            let original = block.recognisedText ?? block.text
            block.recognisedText = text == original ? nil : original
            block.text = text
        }
        block.review = nil
        block.alternative = nil
        items[index].pages[page].blocks[blockIndex] = block
        rebuildDocument(at: index)
        store.save(items[index])
    }

    /// Opens review on a file — at a given page, and region, when there is one
    /// flagged there.
    func startReview(itemID: UUID? = nil, page: Int? = nil, block: Int? = nil) {
        let entries = reviewEntries
        // Asked for no place in particular: carry on where review was left.
        if itemID == nil, let focus = reviewFocus, entries.contains(where: { $0.id == focus }) {
            mode = .review
            return
        }
        let match = entries.first { entry in
            (itemID == nil || entry.itemID == itemID) && (page == nil || entry.page == page)
                && (block == nil || entry.block == block)
        } ?? entries.first { $0.itemID == itemID } ?? entries.first
        reviewFocus = match?.id
        mode = .review
    }

    /// Leaves review for the document, turned to the page and region in question.
    func showInDocument(_ entry: ReviewEntry) {
        selectedIDs = [entry.itemID]
        documentFocus = DocumentFocus(itemID: entry.itemID, page: entry.page, block: entry.block)
        mode = .workspace
    }

    /// Rebuilds the text and the Markdown of every finished result.
    func rebuildDocuments() {
        for index in items.indices where items[index].status == .completed {
            rebuildDocument(at: index)
        }
    }

    private func rebuildDocument(at index: Int) {
        let document = Self.assemble(items[index].pages, dropping: droppedLabels,
                                     inferHeadingLevels: vlConfig.inferHeadingLevels)
        items[index].ocrText = postProcess(document.text)
        items[index].markdown = document.markdown
    }

    /// The document a file's pages make, honouring the page-furniture
    /// preference. Pure, and deliberately not on the main actor.
    nonisolated static func assemble(_ pages: [PageResult], dropping: Set<PPLayoutLabel>,
                                     inferHeadingLevels: Bool) -> (text: String, markdown: String) {
        let parts = pages.map { $0.assembled(dropping: dropping, inferHeadingLevels: inferHeadingLevels) }
        let structured = pages.contains { $0.derivesFromBlocks || !$0.rawMarkdown.isEmpty }
        let text = parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let markdown = structured
            ? parts.map { $0.markdown.isEmpty ? $0.text : $0.markdown }
                .filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
            : ""
        return (text, markdown)
    }

    // MARK: - Diagnostics

    /// A report on the given files — every file when nil — and on the app,
    /// the Mac and the settings they were read with.
    func diagnosticReport(for ids: Set<UUID>? = nil, includingCrashLog: Bool) -> DiagnosticReport {
        let info = Bundle.main.infoDictionary ?? [:]
        let system = DiagnosticReport.currentSystem
        let files = items.filter { ids?.contains($0.id) ?? true }.map { item in
            DiagnosticReport.FileSummary(
                name: item.fileName,
                fileExtension: item.url.pathExtension,
                bytes: (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init),
                pages: max(item.pages.count, item.pageCount),
                status: item.status,
                engine: item.engine,
                error: item.errorMessage,
                pageFailures: item.pages.flatMap(\.notes).compactMap { note in
                    guard case .pageFailed = note.reason else { return nil }
                    return note.message
                })
        }
        return DiagnosticReport(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            system: system.version, machine: system.machine, memoryGB: system.memoryGB,
            settings: settingsSnapshot,
            installedModels: DiagnosticReport.installedModels(in: PPModelStore.userModelsDirectory),
            files: files,
            crashLog: includingCrashLog ? crashLogFromLastSession.flatMap { LaunchSentinel.excerpt(of: $0) } : nil)
    }

    /// Puts a report on the given files on the clipboard, file names left out.
    func copyDiagnostics(for ids: Set<UUID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport(for: ids, includingCrashLog: false)
            .text(includingFileNames: false), forType: .string)
    }

    // MARK: - Folder watching

    /// Watch a folder and read whatever lands in it.
    @Published var watchEnabled = false {
        didSet { persistSettings(); if !isRestoringSettings { updateWatcher() } }
    }
    @Published var watchFolder: URL? {
        didSet { persistSettings(); if !isRestoringSettings { updateWatcher() } }
    }
    /// Where a watched file's result is written, in the export format
    /// currently chosen. Nil keeps the results in the list only.
    @Published var watchOutputFolder: URL? {
        didSet { persistSettings(); if !isRestoringSettings { updateWatcher() } }
    }

    private var watcher: FolderWatcher?
    /// Files the watcher added, exported as each one finishes.
    private var watchedIDs = Set<UUID>()
    /// Watched files arrived while a run was going; they get one of their own
    /// when it ends.
    private var watchBacklog = false

    var isWatching: Bool { watcher != nil }

    /// Picks a folder for the watcher, or for its results.
    func chooseWatchFolder(output: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = output ? String(localized: "Choose an output folder for results") : String(localized: "Choose a folder to watch (including its subfolders)")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if output { watchOutputFolder = url } else { watchFolder = url }
    }

    private func updateWatcher() {
        watcher?.stop()
        watcher = nil
        guard watchEnabled, !isRestoringQueue, let folder = watchFolder else {
            objectWillChange.send()
            return
        }
        let output = watchOutputFolder
        let format = exportFormat
        watcher = FolderWatcher(
            folder: folder, excluding: output,
            shouldTake: { url in
                guard let output else { return true }
                // A file whose result is already in the output folder was
                // read in an earlier session. A Markdown export of a result
                // with no structure is written as plain text instead.
                let probe = ImageItem(url: url, root: folder)
                let formats = format == .markdown ? [format, .plainText] : [format]
                return !formats.contains { format in
                    let result = Self.separateExportURLs(for: [probe], format: format, in: output)[0]
                    return FileManager.default.fileExists(atPath: result.path)
                }
            },
            onFiles: { [weak self] urls in self?.addWatched(urls, root: folder) })
        watcher?.start()
        objectWillChange.send()
    }

    private func addWatched(_ urls: [URL], root: URL) {
        let before = Set(items.map(\.id))
        add(urls.map { ($0, root) })
        let added = items.filter { !before.contains($0.id) }.map(\.id)
        guard !added.isEmpty else { return }
        watchedIDs.formUnion(added)
        if isProcessing || isStopping {
            watchBacklog = true
        } else {
            run(ids: added, useCache: true)
        }
    }

    /// Writes a watched file's result next to the others, as soon as it lands.
    private func exportIfWatched(_ item: ImageItem) {
        guard watchedIDs.remove(item.id) != nil, let output = watchOutputFolder,
              item.isExportable else { return }
        writeSeparately([item], format: resolvedFormat(for: [item]), into: output, reveal: nil)
    }

    // MARK: - Computed helpers

    /// The single item to show in detail panel (last selected, or nil)
    var selectedItem: ImageItem? {
        guard let id = selectedIDs.first else { return nil }
        return items.first { $0.id == id }
    }

    var selectedItems: [ImageItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var failedCount:    Int { items.filter { $0.status == .failed }.count }
    var cancelledCount: Int { items.filter { $0.status == .cancelled }.count }
    /// Finished files with something flagged for a person to check.
    var reviewCount:    Int { items.filter(\.needsReview).count }

    /// How many files each export command would actually write, which is what
    /// the export menu's items are labelled and enabled by.
    var exportableCount: Int { items.filter(\.isExportable).count }
    var exportableSelectedCount: Int { selectedItems.filter(\.isExportable).count }

    // MARK: - File import

    nonisolated static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif",
                                                   "heic", "webp", "pdf"]

    /// Adds files, and everything readable inside folders — subfolders
    /// included. Each file found in a folder remembers that folder, so an
    /// export can lay the results out the way the sources were.
    func addImages(urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            let found = Self.expand(urls)
            await MainActor.run { self.add(found) }
        }
    }

    /// Walks folders on a background thread: a folder of a few thousand scans
    /// should not freeze the window while it is listed.
    nonisolated private static func expand(_ urls: [URL]) -> [(url: URL, root: URL?)] {
        var found: [(url: URL, root: URL?)] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                found.append((url, nil))
                continue
            }
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var inFolder: [URL] = []
            for case let file as URL in walker
            where supportedExtensions.contains(file.pathExtension.lowercased()) {
                inFolder.append(file)
            }
            // Finder order, so the list reads like the folder does.
            inFolder.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            found += inFolder.map { ($0, url) }
        }
        return found
    }

    private func add(_ files: [(url: URL, root: URL?)]) {
        // Compared after resolving symlinks: /tmp and /private/tmp name the same
        // file, and a picker and a drag can hand back different spellings of it.
        var seen = Set(items.map { $0.url.resolvingSymlinksInPath().standardizedFileURL })
        var uniqueNew: [ImageItem] = []
        for file in files where Self.supportedExtensions.contains(file.url.pathExtension.lowercased()) {
            // `seen` grows as we go, so a batch containing the same file twice
            // — an expanded folder overlapping a loose file, say — adds it once.
            guard seen.insert(file.url.resolvingSymlinksInPath().standardizedFileURL).inserted else { continue }
            uniqueNew.append(ImageItem(url: file.url, root: file.root))
        }
        guard !uniqueNew.isEmpty else { return }
        items.append(contentsOf: uniqueNew)
        if selectedIDs.isEmpty, let first = uniqueNew.first { selectedIDs = [first.id] }
        recalcProgress()
        store.saveQueue(items)
        loadThumbnails(for: uniqueNew.map(\.id))
        if autoStartOnAdd {
            Task { @MainActor in self.startProcessing() }
        }
    }

    /// Makes the file list's pictures in the background, a few at a time.
    ///
    /// Decoding every added image in full on the main thread — what the list
    /// used to do to get a thumbnail — froze the window for a folder of
    /// photos and held each one in memory for as long as it stayed listed.
    private func loadThumbnails(for ids: [UUID]) {
        let targets = items.filter { ids.contains($0.id) }.map { ($0.id, $0.url) }
        Task.detached(priority: .utility) { [weak self] in
            for chunk in stride(from: 0, to: targets.count, by: 16).map({ Array(targets[$0..<min($0 + 16, targets.count)]) }) {
                let made = chunk.compactMap { id, url in
                    PageImages.thumbnail(of: url).map { (id, ImageItem.page(from: $0)) }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (id, image) in made {
                        if let index = self.items.firstIndex(where: { $0.id == id }) {
                            self.items[index].thumbnail = image
                        }
                    }
                }
            }
        }
    }

    // MARK: - Screenshot

    /// Lets the user drag out a part of the screen, then reads it like any
    /// other file. The capture is kept in the library folder, so the entry in
    /// the list keeps working after a relaunch.
    func captureScreenshot() {
        let folder = store.directory.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent(String(localized: "Screenshot \(formatter.string(from: Date())).png"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: drag out a region (space bar switches to a window); -x: no sound.
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { [weak self] _ in
            // Escape leaves no file behind, and nothing is added.
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            Task { @MainActor in
                guard let self else { return }
                let before = Set(self.items.map(\.id))
                self.add([(url, nil)])
                if let new = self.items.first(where: { !before.contains($0.id) }) {
                    self.selectedIDs = [new.id]
                    if !self.isProcessing { self.run(ids: [new.id], useCache: false) }
                }
            }
        }
        try? process.run()
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heif, .webP, .pdf,
                                     UTType(filenameExtension: "heic") ?? .heif]
        panel.message = String(localized: "Choose images, PDFs or folders (including their subfolders)")
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK {
            addImages(urls: panel.urls)
        }
    }

    func removeItem(id: UUID) {
        removeItems(ids: [id])
    }

    func removeSelectedItems() {
        removeItems(ids: selectedIDs)
    }

    func removeItems(ids: Set<UUID>) {
        // Determine next selection after removal
        if !selectedIDs.isDisjoint(with: ids) {
            let remaining = items.filter { !ids.contains($0.id) }
            // Pick the item that came right after the last removed one
            if let lastRemovedIdx = items.lastIndex(where: { ids.contains($0.id) }) {
                let candidate = remaining.first(where: { items.firstIndex(of: $0).map { $0 > lastRemovedIdx } ?? false })
                selectedIDs = candidate.map { [$0.id] } ?? (remaining.first.map { [$0.id] } ?? [])
            } else {
                selectedIDs = []
            }
        }
        for item in items where ids.contains(item.id) && item.status != .processing {
            if let key = item.resume?.key { store.removePartial(for: key) }
        }
        items.removeAll { ids.contains($0.id) }
        recalcProgress()
        store.remove(Array(ids))
        store.saveQueue(items)
    }

    func clearAll() {
        store.remove(items.map(\.id))
        store.prunePartials(keeping: [])
        items.removeAll()
        selectedIDs = []
        totalProgress = 0
        isProcessing = false
        store.saveQueue(items)
    }

    // MARK: - OCR processing

    /// Whether a run would actually pick this item up, given `skipCompleted`.
    private func isActionable(_ item: ImageItem) -> Bool {
        switch item.status {
        case .pending, .failed, .cancelled: return true
        case .completed:                    return !skipCompleted
        case .processing:                   return false
        }
    }

    /// How many files 「开始识别」 would process right now.
    ///
    /// The toolbar button and the File menu item both gate on this, so neither
    /// can offer an action that silently does nothing, nor refuse one that
    /// would work — which is what they each used to do, in opposite directions.
    var actionableCount: Int { items.filter(isActionable).count }

    /// When the run in progress started, for the elapsed time beside the bar.
    @Published private(set) var runStartedAt: Date?

    func startProcessing() {
        let ids = items.filter(isActionable).map(\.id)
        // A completed file is only actionable when 「跳过已完成」 is off, and
        // running it again would throw away any corrections made to it.
        let corrected = items.filter { ids.contains($0.id) && $0.isCorrected }
        guard confirmDiscardingCorrections(in: corrected) else { return }
        run(ids: ids, useCache: true)
    }

    /// Re-arms the given items and runs them immediately. A 「重试」 that only
    /// flipped the badge back to pending and waited for a separate
    /// 「开始识别」 read as though nothing had happened.
    ///
    /// Asking to read a file again means reading it again: the recognition
    /// cache is bypassed.
    func retryItems(ids: Set<UUID>) {
        let corrected = items.filter { ids.contains($0.id) && $0.isCorrected }
        guard confirmDiscardingCorrections(in: corrected) else { return }
        for id in ids { retryItem(id: id) }
        run(ids: items.filter { ids.contains($0.id) }.map(\.id), useCache: false)
    }

    /// Hand corrections are the one thing a re-run cannot reproduce, so they
    /// are never thrown away without asking.
    private func confirmDiscardingCorrections(in corrected: [ImageItem]) -> Bool {
        guard !corrected.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = corrected.count == 1
            ? String(localized: "“\(corrected[0].fileName)” has manual edits")
            : String(localized: "\(corrected.count) files have manual edits")
        alert.informativeText = String(localized: "Recognizing again will replace these edits with new results. Export first to keep them.")
        alert.addButton(withTitle: String(localized: "Recognize Again"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func run(ids: [UUID], useCache: Bool) {
        guard !isProcessing, !isStopping, !ids.isEmpty else { return }
        isProcessing = true
        runStartedAt = Date()
        cancellation.reset()

        Task {
            await processConcurrently(ids, useCache: useCache)
            isProcessing = false
            isStopping = false
            runStartedAt = nil
            // Files the watcher found while this run was busy.
            if watchBacklog {
                watchBacklog = false
                let waiting = items.filter { watchedIDs.contains($0.id) && $0.status == .pending }.map(\.id)
                run(ids: waiting, useCache: true)
            }
        }
    }

    /// Runs up to `maxConcurrentTasks` files at once instead of waiting for
    /// each to finish before starting the next. `processItem` moves decoding
    /// and recognition off the main actor, so several files really do make
    /// progress at the same time.
    private func processConcurrently(_ ids: [UUID], useCache: Bool) async {
        var iterator = ids.makeIterator()
        // The GPU engines batch every region they are given, from every page
        // of every file, into one decode; a second file in flight keeps that
        // batch full while the first one's last regions finish. More only
        // queue up, each holding a decoded page in memory.
        let ceiling = ocrEngine.prefersFewFilesInFlight ? min(2, maxConcurrentTasks) : maxConcurrentTasks
        let limit = max(1, min(ceiling, ids.count))
        // `withTaskGroup`'s body closure is not guaranteed to keep the main
        // actor's isolation, so the "still running" check goes through the
        // cancellation token — already `Sendable` and already how `stopProcessing`
        // signals every in-flight item — rather than the actor-isolated
        // `isProcessing` flag.
        let cancelToken = cancellation

        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard !cancelToken.isCancelled, let id = iterator.next() else { return }
                group.addTask { [weak self] in
                    await self?.processItem(id: id, useCache: useCache)
                    await self?.recalcProgress()
                }
            }
            for _ in 0..<limit { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    /// Asks the running images to stop. `isProcessing` stays true until they
    /// have: clearing it here would let 「开始识别」 reset the cancellation token
    /// out from under a worker that is still mid-page, and that worker would
    /// then save its partial output as a completed result — which is exactly
    /// the bug the 已取消 state exists to prevent.
    func stopProcessing() {
        guard isProcessing else { return }
        isStopping = true
        cancellation.cancel()
    }

    func retryItem(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .pending
            items[idx].clearResults()
            // Read from the first page: `processItem` drops the pages kept
            // when it is told not to use what was read before.
            items[idx].resume = nil
        }
    }

    /// Carries stopped documents on from the page they got to.
    func resumeItems(ids: Set<UUID>) {
        run(ids: items.filter { ids.contains($0.id) && isActionable($0) }.map(\.id), useCache: true)
    }

    /// The engine a single file is being read with when it is not the one
    /// selected in the settings — 「用 PaddleOCR-VL 重新识别」 on one file
    /// leaves every other file, and the setting itself, as they were. Kept
    /// across a stop, so carrying the file on reads the rest the same way.
    private var engineOverrides: [UUID: OCREngine] = [:]

    /// Whether 「用 PaddleOCR-VL 重新识别」 applies to this file.
    func canReadWithVL(_ item: ImageItem) -> Bool {
        item.status != .processing && VLModelStore.isInstalled(vlConfig.variant)
            && !(item.status == .completed && item.engine == .paddleVL)
    }

    /// Reads one file again with PaddleOCR-VL alone, whatever engine is
    /// selected.
    func readWithVL(id: UUID) {
        guard !isProcessing, let item = items.first(where: { $0.id == id }) else { return }
        guard confirmDiscardingCorrections(in: item.isCorrected ? [item] : []) else { return }
        engineOverrides[id] = .paddleVL
        retryItem(id: id)
        run(ids: [id], useCache: false)
    }

    // MARK: - Export

    /// Export a specific set of items (defaults to all completed if ids is empty)
    func exportItems(ids: Set<UUID>? = nil) {
        let targets: [ImageItem]
        if let ids, !ids.isEmpty {
            targets = items.filter { ids.contains($0.id) && $0.isExportable }
        } else {
            targets = items.filter(\.isExportable)
        }
        guard !targets.isEmpty else { return }

        let format = resolvedFormat(for: targets)
        switch exportLayout {
        case .combined: exportCombined(targets, format: format)
        case .separate: exportSeparately(targets, format: format)
        }
    }

    /// Markdown is only offered when something in the batch actually has any;
    /// asking for it from a plain Apple Vision run would write a `.md` holding
    /// nothing but the text that a `.txt` would have held.
    private func resolvedFormat(for targets: [ImageItem]) -> ExportFormat {
        guard exportFormat == .markdown, !targets.contains(where: \.hasMarkdown) else {
            return exportFormat
        }
        return .plainText
    }

    private func exportCombined(_ targets: [ImageItem], format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType(for: format)]
        if targets.count == 1 {
            panel.nameFieldStringValue = "\(Self.exportStem(for: targets[0])).\(format.fileExtension)"
            panel.message = String(localized: "Export the results for “\(targets[0].fileName)”")
        } else {
            panel.nameFieldStringValue = "OCRFlow_Results.\(format.fileExtension)"
            panel.message = String(localized: "Export results for \(targets.count) files (combined into one file)")
        }
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch format {
        case .json:
            try? Self.jsonData(targets.map(exportPayload(for:))).write(to: url)
        case .searchablePDF:
            writeSearchablePDFs([(targets, url)], reveal: url)
        case .excel:
            writeWorkbooks([(targets, url)], reveal: url)
        case .markdown, .plainText:
            let text = targets
                .map { item -> String in
                    let body = self.body(of: item, format: format, alongside: url)
                    guard exportIncludeFilename else { return body }
                    return format == .markdown ? "# \(item.fileName)\n\n\(body)"
                                               : "=== \(item.fileName) ===\n\(body)"
                }
                .joined(separator: exportSeparator.separator)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// One file per source, into a folder the user picks. A batch of scans is
    /// usually wanted as a batch of documents, not as one long one.
    ///
    /// Files that came in through a folder are laid out the way that folder
    /// was — `合同/2024/扫描001.pdf_OCR.md` — so a thousand results do not land
    /// in one flat heap with their organisation thrown away.
    private func exportSeparately(_ targets: [ImageItem], format: ExportFormat) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose where to export. \(targets.count) files will each be saved as .\(format.fileExtension), keeping the original folder structure")
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        writeSeparately(targets, format: format, into: folder, reveal: folder)
    }

    /// One result file per item, laid out under `folder` as the sources were.
    /// `reveal` is shown in Finder when the writing is done; nil writes
    /// silently, which is how a watched folder's results are exported.
    private func writeSeparately(_ targets: [ImageItem], format: ExportFormat, into folder: URL, reveal: URL?) {
        var pdfJobs: [([ImageItem], URL)] = []
        var workbookJobs: [([ImageItem], URL)] = []
        for (item, url) in zip(targets, Self.separateExportURLs(for: targets, format: format, in: folder)) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            switch format {
            case .json:
                try? Self.jsonData([exportPayload(for: item)]).write(to: url)
            case .searchablePDF:
                pdfJobs.append(([item], url))
            case .excel:
                workbookJobs.append(([item], url))
            case .markdown, .plainText:
                let body = self.body(of: item, format: format, alongside: url)
                let text = exportIncludeFilename && format == .markdown
                    ? "# \(item.fileName)\n\n\(body)"
                    : body
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        if !pdfJobs.isEmpty {
            writeSearchablePDFs(pdfJobs, reveal: reveal)
        } else if !workbookJobs.isEmpty {
            writeWorkbooks(workbookJobs, reveal: reveal)
        } else if let reveal {
            NSWorkspace.shared.open(reveal)
        }
    }

    /// Where each item's result goes in a separate export, in the order given.
    /// Two items only compete for a name when both were added as loose files
    /// with the same name from different folders; the later one is numbered.
    nonisolated static func separateExportURLs(for items: [ImageItem], format: ExportFormat, in folder: URL) -> [URL] {
        var used = Set<String>()
        return items.map { item in
            let directory = exportDirectory(for: item, in: folder)
            var name = exportStem(for: item)
            var suffix = 2
            while !used.insert(directory.appendingPathComponent(name).path).inserted {
                name = "\(exportStem(for: item))-\(suffix)"
                suffix += 1
            }
            return directory.appendingPathComponent("\(name).\(format.fileExtension)")
        }
    }

    /// A result's name keeps the source's whole name, extension included, so
    /// `scan.png` and `scan.pdf` in one folder can never claim the same file
    /// — not in one export, and not across a watched folder's one-at-a-time
    /// exports either.
    nonisolated static func exportStem(for item: ImageItem) -> String {
        "\(item.fileName)_OCR"
    }

    /// Writes each group's tables to a workbook. A group with no recognised
    /// table writes nothing — an empty workbook would only look like a loss.
    private func writeWorkbooks(_ jobs: [([ImageItem], URL)], reveal: URL?) {
        var written = 0
        for (items, url) in jobs {
            let sheets = TableWorkbook.sheets(from: items)
            guard !sheets.isEmpty else { continue }
            do {
                try TableWorkbook.write(sheets, to: url)
                written += 1
            } catch {
                continue
            }
        }
        guard let reveal else { return }
        if written == 0 {
            let alert = NSAlert()
            alert.messageText = String(localized: "No Tables to Export")
            alert.informativeText = String(localized: "Only tables whose structure was recognized by PaddleOCR-VL (or the VL layer in Smart Layering) can be exported to Excel. Tables PP-OCRv6 read as plain text have no cell information.")
            alert.runModal()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([reveal])
        }
    }

    /// Where a file's result goes: under the folder it came in through, at
    /// the same place it sat in that folder.
    nonisolated static func exportDirectory(for item: ImageItem, in folder: URL) -> URL {
        guard let root = item.root else { return folder }
        let relative = (item.relativePath as NSString).deletingLastPathComponent
        let base = folder.appendingPathComponent(root.lastPathComponent, isDirectory: true)
        return relative.isEmpty ? base : base.appendingPathComponent(relative, isDirectory: true)
    }

    /// Writes PDFs off the main thread — redrawing a few hundred pages takes a
    /// while — and says so if any could not be written.
    private func writeSearchablePDFs(_ jobs: [([ImageItem], URL)], reveal: URL?) {
        Task.detached(priority: .userInitiated) {
            let failures = jobs.compactMap { items, url -> String? in
                do {
                    try SearchablePDFWriter.write(items, to: url)
                    return nil
                } catch {
                    return String(localized: "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                guard let reveal else { return }
                if failures.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([reveal])
                } else {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "\(failures.count) PDFs couldn't be written")
                    alert.informativeText = failures.prefix(8).joined(separator: "\n")
                    alert.runModal()
                }
            }
        }
    }

    private func body(of item: ImageItem, format: ExportFormat, alongside file: URL) -> String {
        switch format {
        case .plainText, .json, .searchablePDF, .excel:
            return item.ocrText
        case .markdown:
            guard item.hasMarkdown else { return item.ocrText }
            guard exportFigures else { return item.markdown }
            return writingFigures(of: item, from: item.markdown, alongside: file)
        }
    }

    private static func contentType(for format: ExportFormat) -> UTType {
        switch format {
        case .markdown:      return UTType(filenameExtension: "md") ?? .plainText
        case .plainText:     return .plainText
        case .json:          return .json
        case .searchablePDF: return .pdf
        case .excel:         return UTType(filenameExtension: "xlsx") ?? .data
        }
    }

    // MARK: - JSON export

    /// The structured result, in the shape the rest of the world can read:
    /// every page, every line with its box and confidence, every region with
    /// its label, its place in the reading order, who read it and why.
    private struct ExportedFile: Encodable {
        struct Page: Encodable {
            struct Line: Encodable {
                var text: String
                var confidence: Double
                /// Four corner points, clockwise from the top left, in image pixels.
                var quad: [[Double]]
            }
            struct Region: Encodable {
                var label: String
                var readingOrder: Int
                var score: Double
                /// `[x, y, width, height]` in image pixels.
                var box: [Double]
                var text: String
                var isPageFurniture: Bool
                /// `vlm`, `ppocr` or `pdf_text`.
                var source: String
                var routing: String?
                var review: String?
                /// What the engine read, when the text has been corrected since.
                var recognisedText: String?
            }
            var index: Int
            var width: Double
            var height: Double
            var text: String
            var markdown: String?
            var lines: [Line]
            var regions: [Region]
            var notes: [String]
        }
        var schemaVersion = 2
        var file: String
        var path: String
        var engine: String?
        var text: String
        var markdown: String?
        var pages: [Page]
    }

    private func exportPayload(for item: ImageItem) -> ExportedFile {
        let pages = item.pages.enumerated().map { index, page -> ExportedFile.Page in
            let assembled = pageText(for: item, page: index)
            return ExportedFile.Page(
                index: index + 1,
                width: page.size.width, height: page.size.height,
                text: assembled.text,
                markdown: assembled.markdown.isEmpty ? nil : assembled.markdown,
                lines: page.lines.map { line in
                    .init(text: line.text, confidence: line.confidence,
                          quad: line.quad.map { [Double($0.x), Double($0.y)] })
                },
                regions: page.blocks.map { block in
                    .init(label: block.label.rawName, readingOrder: block.readingOrder,
                          score: block.score,
                          box: [Double(block.rect.minX), Double(block.rect.minY),
                                Double(block.rect.width), Double(block.rect.height)],
                          text: block.text, isPageFurniture: block.label.isPageFurniture,
                          source: Self.exportName(for: block.source ?? page.blockSource),
                          routing: block.routing?.message, review: block.review?.message,
                          recognisedText: block.recognisedText)
                },
                notes: page.notes.map(\.message))
        }
        return ExportedFile(file: item.fileName, path: item.url.path, engine: item.engine?.rawValue,
                            text: item.ocrText, markdown: item.hasMarkdown ? item.markdown : nil,
                            pages: pages)
    }

    private static func exportName(for source: PPTextSource) -> String {
        switch source {
        case .visionLanguageModel: return "vlm"
        case .plainOCR:            return "ppocr"
        case .pdfTextLayer:        return "pdf_text"
        }
    }

    private static func jsonData(_ files: [ExportedFile]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(files)) ?? Data()
    }

    /// Saves the figures a document points at into a folder beside the exported
    /// file and rewrites the placeholders to reference them.
    ///
    /// Without this the `![图片]()` placeholders leave the export with broken
    /// images: the pictures only exist inside the source page. Every page's
    /// figures are written — each page is decoded again for it — and a
    /// figure that cannot be cropped keeps its empty placeholder.
    private func writingFigures(of item: ImageItem, from markdown: String,
                                alongside file: URL) -> String {
        var crops: [NSImage?] = []
        let pdf = item.isPDF ? PDFSource(url: item.url) : nil
        for (index, page) in item.pages.enumerated() {
            let figureCount = PPDocumentAssembler.contentIndices(page.blocks, dropping: droppedLabels)
                .filter { page.blocks[$0].label.producesFigure }.count
            guard figureCount > 0 else { continue }
            let image = page.rectified?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                ?? (pdf.flatMap { $0.render(page: index)?.image } ?? PageImages.image(at: item.url, frame: index))
            crops += DocumentFigures.crops(for: page, image: image, dropping: droppedLabels)
        }
        guard crops.contains(where: { $0 != nil }) else { return markdown }

        let stem = file.deletingPathExtension().lastPathComponent
        let folderName = "\(stem).assets"
        let folder = file.deletingLastPathComponent().appendingPathComponent(folderName)
        guard (try? FileManager.default.createDirectory(at: folder,
                                                        withIntermediateDirectories: true)) != nil
        else { return markdown }

        let prefix = Self.sanitizedFileStem((item.fileName as NSString).deletingPathExtension)
        var links: [String] = []
        for (index, crop) in crops.enumerated() {
            guard let data = crop?.pngData else {
                links.append("")
                continue
            }
            let name = "\(prefix)-\(index + 1).png"
            do {
                try data.write(to: folder.appendingPathComponent(name))
                let path = "\(folderName)/\(name)"
                links.append(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
            } catch {
                links.append("")
            }
        }
        return PPDocumentAssembler.rewritingFigureLinks(in: markdown, to: links)
    }

    /// Keeps a source file's name usable as part of a figure's file name.
    private static func sanitizedFileStem(_ stem: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "figure" : cleaned
    }

    func exportSelectedItems() {
        exportItems(ids: selectedIDs)
    }

    func exportResults() {
        exportItems(ids: nil)
    }

    func copyText(for id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.ocrText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.ocrText, forType: .string)
    }

    /// Copies the structured document rather than the flattened text, which is
    /// what the Markdown and source panes are showing.
    func copyMarkdown(for id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.hasMarkdown else {
            copyText(for: id)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.markdown, forType: .string)
    }

    func copySelectedText() {
        let text = selectedItems
            .filter { $0.status == .completed }
            .map(\.ocrText)
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Private

    private func processItem(id: UUID, useCache: Bool) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .processing
        items[idx].processingProgress = 0
        items[idx].pagesDone = 0
        items[idx].pageCount = 0
        items[idx].reusedCachedResult = false

        let url = items[idx].url
        var settings = currentRecognitionSettings()
        if let engine = engineOverrides[id] { settings.engine = engine }
        let cancelToken = cancellation
        let store = self.store
        let started = Date()
        // Where this file's pages are kept as they are read, once known.
        var resumeKey: String?
        var pageTotal = 0

        let reportProgress: DocumentRecognizer.Progress = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, let i = self.items.firstIndex(where: { $0.id == id }),
                      self.items[i].status == .processing else { return }
                self.items[i].processingProgress = update.fraction
                self.items[i].pagesDone = update.pagesDone
                self.items[i].pageCount = update.pageCount
                self.recalcProgress()
            }
        }

        do {
            let engines = try await loadEngines(for: settings)
            let fingerprint = settings.fingerprint(
                vlAvailable: engines.layered?.vl != nil || engines.vlPipeline != nil,
                layoutAvailable: engines.paddle?.hasLayoutAnalysis ?? false,
                unwarping: engines.unwarper != nil)

            // Hashing a large file and reading back the pages an earlier run
            // kept both take a moment; neither belongs on the main actor.
            let prepared = await Task.detached(priority: .userInitiated) {
                () -> (key: String?, cached: [PageResult]?, count: Int, done: [Int: PageResult]) in
                let key = ResultStore.cacheKey(for: url, fingerprint: fingerprint)
                if useCache, let key, let pages = store.cachedPages(for: key) {
                    return (key, pages, pages.count, [:])
                }
                // Only a document long enough to be stopped part-way is worth
                // keeping page by page.
                let count = DocumentRecognizer.pageCount(of: url)
                guard let key, count > 1 else { return (key, nil, count, [:]) }
                // Asked to read the file again: what was kept is not used.
                guard useCache else {
                    store.removePartial(for: key)
                    return (key, nil, count, [:])
                }
                return (key, nil, count, store.partialPages(for: key))
            }.value

            let outcome: (pages: [PageResult], cached: Bool)
            if let cached = prepared.cached {
                outcome = (cached, true)
            } else {
                if let key = prepared.key, prepared.count > 1 {
                    resumeKey = key
                    pageTotal = prepared.count
                    // Saved now, so a crash part-way still knows where the
                    // pages it read are.
                    if let i = items.firstIndex(where: { $0.id == id }) {
                        items[i].resume = ResumePoint(key: key, total: prepared.count, read: prepared.done.count)
                        store.saveQueue(items)
                    }
                }
                let keepKey = resumeKey
                let done = prepared.done
                // Decoding and recognition run entirely off the main actor, so
                // several files make real progress at once when
                // `startProcessing` fans a batch out across a task group,
                // instead of each one blocking the actor in turn.
                outcome = try await Task.detached(priority: .userInitiated) { () -> (pages: [PageResult], cached: Bool) in
                    let pages = try DocumentRecognizer.recognize(
                        url: url, settings: settings, engines: engines, done: done,
                        isCancelled: { cancelToken.isCancelled },
                        progress: reportProgress,
                        onPage: keepKey.map { key in
                            { @Sendable index, page in store.savePartialPage(page, index: index, for: key) }
                        })
                    // Only a complete, clean reading is worth serving again.
                    let failedPage = pages.contains { $0.size == .zero }
                    if let key = prepared.key, !cancelToken.isCancelled, !failedPage {
                        store.cache(pages, for: key)
                    }
                    return (pages, false)
                }.value
            }

            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            // The engines answer a cancellation by returning early, so a
            // stopped run comes back like any other — just with part of the
            // page missing. Saving that as a result is what made a stopped
            // newspaper look like a page of nothing but image placeholders.
            // The pages finished before the stop are kept apart, for 继续识别.
            guard !cancelToken.isCancelled || outcome.cached else {
                var stopped = items[i]
                stopped.clearResults()
                stopped.status = .cancelled
                stopped.resume = resumePoint(key: resumeKey, total: pageTotal)
                items[i] = stopped
                store.saveQueue(items)
                return
            }
            var updated = items[i]
            let document = Self.assemble(outcome.pages, dropping: droppedLabels,
                                         inferHeadingLevels: vlConfig.inferHeadingLevels)
            updated.status = .completed
            updated.pages = outcome.pages
            updated.ocrText = postProcess(document.text)
            updated.markdown = document.markdown
            updated.engine = settings.engine
            updated.errorMessage = nil
            updated.elapsed = Date().timeIntervalSince(started)
            updated.reusedCachedResult = outcome.cached
            updated.processingProgress = 1.0
            updated.resume = nil
            items[i] = updated          // single assignment → one objectWillChange
            engineOverrides[id] = nil
            if let resumeKey { store.removePartial(for: resumeKey) }
            store.save(updated)
            store.saveQueue(items)
            exportIfWatched(updated)
        } catch {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            var updated = items[i]
            // A failed run has no results, so anything still attached belongs to
            // an earlier one and would otherwise keep showing.
            updated.clearResults()
            // An engine that threw on its way out of a cancelled run was
            // stopped, not broken; saying 失败 would send the user looking for
            // a problem with the file.
            updated.status = cancelToken.isCancelled ? .cancelled : .failed
            updated.errorMessage = cancelToken.isCancelled ? nil : error.localizedDescription
            // Whatever pages did get read are still worth carrying on from.
            updated.resume = resumePoint(key: resumeKey, total: pageTotal)
            if !cancelToken.isCancelled { engineOverrides[id] = nil }
            items[i] = updated
            store.save(updated)
            store.saveQueue(items)
        }
    }

    /// Where a document that stopped part-way got to, counted from the pages
    /// actually on disk; nil when it got nowhere.
    private func resumePoint(key: String?, total: Int) -> ResumePoint? {
        guard let key else { return nil }
        let read = store.partialPageCount(for: key)
        return read > 0 ? ResumePoint(key: key, total: total, read: read) : nil
    }

    private func currentRecognitionSettings() -> DocumentRecognizer.Settings {
        DocumentRecognizer.Settings(engine: ocrEngine, visionLanguages: recognitionLanguages,
                                    paddleConfig: paddleConfig, vlConfig: vlConfig,
                                    layered: layeredConfig)
    }

    // MARK: - Engines

    /// The engine load in progress, which the next one waits for.
    private var engineLoading: Task<DocumentRecognizer.Engines, Error>?

    /// Loads what the selected engine needs, reusing whatever is already
    /// loaded and still matches the settings.
    ///
    /// Loads happen one after another. Two files start together, and both
    /// would otherwise find nothing loaded and each load the models — a
    /// second gigabyte-and-a-half copy of the VLM, and its shaders compiled
    /// twice. Waiting for the first means the second finds them loaded.
    private func loadEngines(for settings: DocumentRecognizer.Settings) async throws -> DocumentRecognizer.Engines {
        let previous = engineLoading
        let load = Task { @MainActor in
            _ = try? await previous?.value
            return try await self.loadEnginesNow(for: settings)
        }
        engineLoading = load
        defer { if engineLoading == load { engineLoading = nil } }
        return try await load.value
    }

    private func loadEnginesNow(for settings: DocumentRecognizer.Settings) async throws -> DocumentRecognizer.Engines {
        var engines = DocumentRecognizer.Engines()
        engines.unwarper = await loadDocUnwarper()
        switch settings.engine {
        case .visionFast, .visionAccurate:
            break
        case .paddleOCR:
            engines.paddle = try await loadPaddleEngine(for: settings.paddleConfig)
        case .paddleVL:
            engines.vlPipeline = try await loadVLPipeline(for: settings.vlConfig)
        case .auto:
            // The layout model is what the routing is decided on, so the PP-OCR
            // engine is built with it whenever it is installed.
            var paddle = settings.paddleConfig
            if VLModelStore.isLayoutModelInstalled { paddle.readingOrder = .layout }
            let engine = try await loadPaddleEngine(for: paddle)
            var vl: VLEngine?
            if VLModelStore.isInstalled(settings.vlConfig.variant) {
                do {
                    vl = try await loadVLEngine(for: settings.vlConfig)
                } catch {
                    engines.vlUnavailable = error.localizedDescription
                }
            }
            engines.paddle = engine
            engines.layered = LayeredPipeline(paddle: engine, vl: vl, paddleConfig: paddle,
                                              vlConfig: settings.vlConfig, config: settings.layered)
        }
        return engines
    }

    /// The VLM on its own, reusing the loaded weights when the configuration
    /// has not changed. Loading costs seconds and a gigabyte or more, so this
    /// is deliberately sticky.
    private func loadVLEngine(for config: VLConfig) async throws -> VLEngine {
        if let vlEngine, vlEngine.matchesModelConfiguration(config) { return vlEngine }
        // Drop the old weights before loading new ones, rather than holding
        // both for the length of the load.
        vlEngine = nil
        let engine = try await Task.detached(priority: .userInitiated) {
            try VLEngine(config: config)
        }.value
        vlEngine = engine
        return engine
    }

    /// Builds the PaddleOCR-VL pipeline: the VLM, and the layout stage in
    /// front of it.
    private func loadVLPipeline(for config: VLConfig) async throws -> VLDocumentPipeline {
        let engine = try await loadVLEngine(for: config)

        var detector: PPLayoutDetector?
        if config.useLayoutDetection {
            if vlLayoutSession == nil {
                let modelURL = try VLModelStore.resolveLayoutModel()
                let env = try ORTEnv(loggingLevel: .error)
                vlLayoutEnv = env
                vlLayoutSession = try await Task.detached(priority: .userInitiated) {
                    try PPSession(modelPath: modelURL, env: env, config: .default)
                }.value
            }
            detector = vlLayoutSession.map(PPLayoutDetector.init)
        }

        return VLDocumentPipeline(layout: detector, vl: engine)
    }

    /// Loads UVDoc if the setting asks for it and the file is there. A missing
    /// model is not an error: the page is simply read as photographed.
    private func loadDocUnwarper() async -> PPDocUnwarper? {
        guard useDocUnwarping, PPModelStore.isUnwarpingModelInstalled else { return nil }
        if let docUnwarper { return docUnwarper }
        guard let url = try? PPModelStore.resolveUnwarpingModel(),
              let env = try? ORTEnv(loggingLevel: .error) else { return nil }
        let session = try? await Task.detached(priority: .userInitiated) {
            try PPSession(modelPath: url, env: env, config: .default)
        }.value
        guard let session else { return nil }
        docUnwarperEnv = env
        docUnwarper = PPDocUnwarper(session: session)
        return docUnwarper
    }

    /// Reuses the loaded ONNX sessions unless the model files or backend changed.
    private func loadPaddleEngine(for config: PPOCRConfig) async throws -> PPOCREngine {
        if let engine = paddleEngine, engine.matchesModelConfiguration(config) { return engine }
        // Building an engine reads ~29 MB of model files; keep it off the main
        // thread so the window stays responsive on the first run.
        let engine = try await Task.detached(priority: .userInitiated) {
            try PPOCREngine(config: config)
        }.value
        paddleEngine = engine
        return engine
    }

    // MARK: - Text post-processing

    private func postProcess(_ raw: String) -> String {
        var text = raw

        // 1. 去除连字符换行："exam-\nple" → "example"
        if removeHyphenBreaks {
            text = text.replacingOccurrences(of: "-\n", with: "")
        }

        // 2. 每行首尾去空格
        if trimWhitespace {
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
        }

        // 3. 合并连续空行为单个空行
        if removeEmptyLines {
            let multipleNewlines = try? NSRegularExpression(pattern: "\n{3,}", options: [])
            text = multipleNewlines?.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n"
            ) ?? text
        }

        // 4. 合并所有换行为空格（不换行模式）—— 放最后执行
        if mergeLineBreaks {
            text = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        return text
    }

    /// Overall progress, counting the file being read as the fraction of it
    /// that has been read.
    ///
    /// Counting only finished files meant a single-file run sat at 0% for its
    /// whole duration and then jumped to 100% — with the detail pane showing
    /// 32% right beside it, which is a contradiction rather than a delay.
    private func recalcProgress() {
        guard !items.isEmpty else { totalProgress = 0; return }
        let settled = items.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }.count
        let inFlight = items
            .filter { $0.status == .processing }
            .reduce(0.0) { $0 + min(max($1.processingProgress, 0), 1) }
        totalProgress = min(1, (Double(settled) + inFlight) / Double(items.count))
    }
}

enum OCRError: LocalizedError {
    case imageLoadFailed
    case pdfOpenFailed

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed: return String(localized: "Couldn't load the image file")
        case .pdfOpenFailed:   return String(localized: "Couldn't open the PDF (it's damaged or password-protected)")
        }
    }
}
