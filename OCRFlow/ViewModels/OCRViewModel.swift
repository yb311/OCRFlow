import Foundation
import AppKit
import Vision
import UniformTypeIdentifiers
import OnnxRuntimeBindings
import os

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
        case .paddleOCR:      return String(localized: "Quick reading")
        case .paddleVL:       return String(localized: "Close reading")
        }
    }

    /// Engines whose models live on the GPU and serve many regions at once:
    /// two files in flight keep them fed, more only queue.
    var prefersFewFilesInFlight: Bool { self == .auto || self == .paddleVL }

    /// Vision picks languages from a list; the PaddleOCR engines pick them by
    /// model file, and PaddleOCR-VL is multilingual with no setting at all.
    var usesVisionLanguages: Bool { self == .visionFast || self == .visionAccurate }
}

// MARK: - Quality presets

/// How much time a page is worth — the one choice the settings lead with.
///
/// Each preset is a consistent set of the engine and model settings that sit
/// under 高级: which engine, which model sizes, how hard detection looks and
/// how readily a doubtful region is read a second time. Someone who only
/// wants "faster" or "better" picks one; the individual knobs stay for anyone
/// who wants them, and touching one shows the setup as 自定义.
enum QualityPreset: String, CaseIterable, Identifiable {
    case fast, balanced, accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast:     return String(localized: "Fast")
        case .balanced: return String(localized: "Balanced")
        case .accurate: return String(localized: "Accurate")
        }
    }

    var hint: String {
        switch self {
        case .fast:
            return String(localized: "Reads text only. The fastest, but tables, formulas, charts and seals come out as plain text.")
        case .balanced:
            return String(localized: "Body text is read quickly; tables, formulas and passages it is unsure of get a closer reading, and text already in a PDF is taken as it is. Good results at a good speed (recommended).")
        case .accurate:
            return String(localized: "Like Balanced, with the largest installed models, finer text detection and more passages read twice. The best results, and the slowest.")
        }
    }

    /// Detection resolution: higher finds smaller print, at a cost.
    var detectionSide: Int { self == .accurate ? 1280 : 960 }

    /// PaddleOCR-VL's answer budget per region.
    var vlOutputTokens: Int { self == .accurate ? 2048 : 1024 }

    /// Below this average PP-OCRv6 confidence a region is read again.
    var escalationConfidence: Double { self == .accurate ? 0.92 : 0.85 }

    var engine: OCREngine { self == .fast ? .paddleOCR : .auto }

    /// The biggest PP-OCRv6 tier this preset wants that is on disk.
    var tier: PPModelTier {
        self == .accurate && PPModelStore.isInstalled(.medium) ? .medium : .small
    }

    /// The PaddleOCR-VL weights this preset wants, of those on disk.
    func vlVariant(current: VLModelVariant) -> VLModelVariant {
        let wanted: VLModelVariant = self == .accurate ? .official : .quantized
        if VLModelStore.isInstalled(wanted) { return wanted }
        return VLModelVariant.allCases.first(where: VLModelStore.isInstalled) ?? current
    }

    /// Models that would make this preset better and are not installed yet.
    var missingModels: [PPModelCatalog.Entry] {
        var entries: [PPModelCatalog.Entry] = []
        if self != .fast, !VLModelVariant.allCases.contains(where: VLModelStore.isInstalled) {
            entries.append(PPModelCatalog.vlQuantized)
        }
        if !VLModelStore.isLayoutModelInstalled { entries.append(PPModelCatalog.layoutModel) }
        if self == .accurate, !PPModelStore.isInstalled(.medium) { entries.append(PPModelCatalog.mediumTier) }
        return entries.filter { !$0.isInstalled }
    }
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
    /// Off: the page shows as the page, and a region is outlined where the
    /// pointer is. Every box at once is an analysis view, not a reading one.
    var showTextBoxes = false
    var paddle: PPOCRConfig = .default
    var vl: VLConfig = .default
    var layered: LayeredConfig = .default
    var mergeLineBreaks = false
    var removeEmptyLines = false
    var trimWhitespace = true
    var removeHyphenBreaks = false
    /// Dropping a file in is asking for it to be read.
    var autoStartOnAdd = true
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
    /// unreadable. Footnotes are kept: they are part of what a page says,
    /// and text that is framed on the page but missing from the result reads
    /// as a recognition failure.
    var keptAuxiliary: [String] = [PPLayoutLabel.footnote.rawName]
    var useDocUnwarping = false
    var watchEnabled = false
    var watchFolderPath: String?
    var watchOutputPath: String?
    var autoTranslate = false
    var translationTarget = DocumentTranslation.defaultTarget
    var globalCaptureShortcut = true
    var showFloatingButton = false
    /// Where screenshots are saved, without asking each time. Nil: the
    /// desktop, where the Mac's own screenshots go.
    var screenshotFolderPath: String?
    var screenshotFormat: ScreenshotFormat = .png
    /// Several pages saved at once — a recording, a queue — as one PDF, or a
    /// picture each.
    var savesPagesAsPDF = true
}

extension OCRSettings {
    /// Decodes field by field, falling back to the default for anything missing
    /// or no longer readable. A setting added or changed in a later version
    /// then takes its default, instead of throwing and resetting everything
    /// the user had tuned.
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
        dropPageFurniture = value(.dropPageFurniture, fallback.dropPageFurniture)
        useDocUnwarping = value(.useDocUnwarping, fallback.useDocUnwarping)
        watchEnabled = value(.watchEnabled, fallback.watchEnabled)
        watchFolderPath = try? container.decodeIfPresent(String.self, forKey: .watchFolderPath)
        watchOutputPath = try? container.decodeIfPresent(String.self, forKey: .watchOutputPath)
        autoTranslate = value(.autoTranslate, fallback.autoTranslate)
        translationTarget = value(.translationTarget, fallback.translationTarget)
        globalCaptureShortcut = value(.globalCaptureShortcut, fallback.globalCaptureShortcut)
        showFloatingButton = value(.showFloatingButton, fallback.showFloatingButton)
        screenshotFolderPath = try? container.decodeIfPresent(String.self, forKey: .screenshotFolderPath)
        screenshotFormat = value(.screenshotFormat, fallback.screenshotFormat)
        savesPagesAsPDF = value(.savesPagesAsPDF, fallback.savesPagesAsPDF)
        keptAuxiliary = value(.keptAuxiliary, fallback.keptAuxiliary)
    }
}

@MainActor
@Observable
final class OCRViewModel {

    // MARK: - State

    var items: [ImageItem] = []
    var selectedIDs: Set<UUID> = []
    /// Whether the window is browsing documents or working through what was
    /// flagged for review.
    var mode: WorkspaceMode = .workspace
    /// The flagged item the review pane is on.
    var reviewFocus: ReviewEntry.Key?
    /// A page and region the document pane should turn to, set when leaving
    /// review for "在文档中查看". The pane clears it once it has moved.
    var documentFocus: DocumentFocus?
    /// What the sidebar is searching for. The document pane reads it too, to
    /// open a file found by its contents at the place it says that.
    var searchQuery = ""
    /// Bumped by 查找 (⌘F) to put the cursor in the sidebar's search field.
    var searchFocusRequest = 0
    var isProcessing = false
    /// Set between pressing 停止 and the last in-flight image actually letting
    /// go. A run cannot be restarted in that window: the worker still holds the
    /// cancellation token, and re-arming it would let a half-finished page be
    /// written out as a finished one.
    private(set) var isStopping = false
    var totalProgress: Double = 0        // 0.0 – 1.0
    var recognitionLanguages: [String] = OCRSettings().recognitionLanguages {
        didSet { persistSettings() }
    }
    var ocrEngine: OCREngine = OCRSettings().engine {
        didSet { persistSettings() }
    }
    /// How many images `startProcessing` runs at once. Decoding and Vision
    /// recognition genuinely parallelise across cores; PaddleOCR's own engine
    /// still finishes one recognition before starting the next regardless of
    /// this value (see `processConcurrently`).
    var maxConcurrentTasks: Int = OCRViewModel.defaultConcurrency {
        didSet { persistSettings() }
    }

    /// Nonisolated so `OCRSettings` can use it as a default without hopping to
    /// the main actor; it only reads the process's core count.
    nonisolated static var defaultConcurrency: Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    // MARK: - PaddleOCR settings
    var paddleConfig: PPOCRConfig = .default {
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
    var showTextBoxes = OCRSettings().showTextBoxes {
        didSet { persistSettings() }
    }

    // MARK: - PaddleOCR-VL settings
    var vlConfig: VLConfig = .default {
        didSet {
            if let engine = vlEngine, !engine.matchesModelConfiguration(vlConfig) {
                vlEngine = nil
            }
            persistSettings()
        }
    }

    // MARK: - 智能分层 settings
    var layeredConfig: LayeredConfig = .default {
        didSet { persistSettings() }
    }

    /// Loaded VLM weights, kept alive across images. Held separately from the
    /// PP-OCR engine because the two can be swapped independently.
    @ObservationIgnored private var vlEngine: VLEngine?
    /// The layout stage, loaded alongside the VLM.
    @ObservationIgnored private var vlLayoutSession: PPSession?
    @ObservationIgnored private var vlLayoutEnv: ORTEnv?

    /// Loaded ONNX sessions, kept alive across images.
    @ObservationIgnored private var paddleEngine: PPOCREngine?
    /// UVDoc, loaded the first time a page has to be flattened.
    @ObservationIgnored private var docUnwarper: PPDocUnwarper?
    @ObservationIgnored private var docUnwarperEnv: ORTEnv?
    @ObservationIgnored private var docOrienter: PPDocOrientationClassifier?
    @ObservationIgnored private var docOrienterEnv: ORTEnv?
    /// Read from the OCR worker thread to honour the Stop button mid-image.
    private let cancellation = PPCancellationToken()

    /// Installs the models that are not bundled.
    let modelDownloader = PPModelDownloader()

    /// The queue and its results on disk, and the recognition cache.
    let store: ResultStore
    /// False until the queue saved by the last session has been read back;
    /// the list shows nothing actionable before then.
    private(set) var isRestoringQueue = true

    /// The crash log the last session left, when it ended in a crash. The
    /// window offers to report it once, then it is cleared.
    var crashLogFromLastSession: URL?

    /// A question or a message for the user, which the main window shows.
    var prompt: UserPrompt?
    private let sentinel: LaunchSentinel

    init() {
        store = ResultStore()
        macros = MacroLibrary(directory: store.directory)
        sentinel = LaunchSentinel(directory: store.directory)
        crashLogFromLastSession = sentinel.begin()
        restoreSettings()
        validateModelSelections()
        validateTranslationTarget()
        // Write the settings back in their normalised form. Without this a file
        // that was partial, or written by an older build, stays that way on disk
        // until the user happens to change something.
        persistSettings()
        translator.owner = self
        updateCaptureShortcut()
        updatePresence()

        // A model the user just deleted may be the one currently selected.
        modelDownloader.onInventoryChange = { [weak self] in self?.validateModelSelections() }
        restoreQueue()
    }

    /// Called as the app quits. llama.cpp tears its Metal device down in a
    /// static destructor and asserts if a model is still loaded at that
    /// point, which crashes the app on quit. Releasing the engine while the
    /// run loop is still alive keeps the teardown in the right order.
    func prepareForTermination() {
        store.saveQueue(items)
        releaseVLEngine()
        sentinel.end()
    }

    /// Reads back the list the last session left: every file, its status and
    /// its result. A file that was being read when the app went away comes
    /// back as 待处理, and 开始识别 carries on from there.
    private func restoreQueue() {
        let store = self.store
        Task {
            let restored = await BlockingWork.run { store.load() }
            // Anything added while the queue was loading goes after it.
            let added = items
            let restoredURLs = Set(restored.map(\.url))
            var all = restored
            all.append(contentsOf: added.filter { !restoredURLs.contains($0.url) })
            items = all
            settleEquivalentReadings()
            rebuildDocuments()
            if selectedIDs.isEmpty, let first = all.first { selectedIDs = [first.id] }
            isRestoringQueue = false
            recalcProgress()
            updateWatcher()
            store.pruneResults(keeping: Set(all.map(\.id)))
            recordMissingHistory()
            store.prunePartials(keeping: Set(all.compactMap(\.resume?.key)))
            loadThumbnails(for: restored.map(\.id))
        }
    }

    // MARK: - Settings persistence

    nonisolated private static let settingsKey = "OCRFlow.settings"

    /// Set while the stored values are being written back into the published
    /// properties, so each one's `didSet` does not save what was just loaded.
    @ObservationIgnored private var isRestoringSettings = false

    var settingsSnapshot: OCRSettings {
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
                    watchFolderPath: watchFolder?.path(percentEncoded: false),
                    watchOutputPath: watchOutputFolder?.path(percentEncoded: false),
                    autoTranslate: autoTranslate,
                    translationTarget: translationTarget,
                    globalCaptureShortcut: globalCaptureShortcut,
                    showFloatingButton: showFloatingButton,
                    screenshotFolderPath: screenshotFolder?.path(percentEncoded: false),
                    screenshotFormat: screenshotFormat,
                    savesPagesAsPDF: savesPagesAsPDF)
    }

    private func persistSettings() {
        guard !isRestoringSettings else { return }
        guard let data = try? JSONEncoder().encode(settingsSnapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func restoreSettings() {
        guard let stored = Self.savedSettings else { return }
        apply(stored)
    }

    /// What the last session saved, if anything. Read on its own by the app
    /// delegate, which has to settle the Dock icon before this model exists.
    nonisolated static var savedSettings: OCRSettings? {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else { return nil }
        return try? JSONDecoder().decode(OCRSettings.self, from: data)
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
        watchFolder = settings.watchFolderPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
        watchOutputFolder = settings.watchOutputPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
        watchEnabled = settings.watchEnabled
        autoTranslate = settings.autoTranslate
        translationTarget = settings.translationTarget
        globalCaptureShortcut = settings.globalCaptureShortcut
        showFloatingButton = settings.showFloatingButton
        screenshotFolder = settings.screenshotFolderPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
        screenshotFormat = settings.screenshotFormat
        savesPagesAsPDF = settings.savesPagesAsPDF
    }

    func resetAllSettings() {
        apply(OCRSettings())
        validateModelSelections()
        validateTranslationTarget()
        persistSettings()
        updateWatcher()
        updateCaptureShortcut()
        updatePresence()
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

    /// The preset the current setup amounts to, or nil when it has been
    /// tuned into something none of them is (自定义).
    var qualityPreset: QualityPreset? {
        QualityPreset.allCases.first(where: matches)
    }

    private func matches(_ preset: QualityPreset) -> Bool {
        guard ocrEngine == preset.engine, paddleConfig.tier == preset.tier,
              paddleConfig.detLimitSideLen == preset.detectionSide else { return false }
        let tierDefaults = preset.tier.detectionDefaults
        guard paddleConfig.detThresh == tierDefaults.thresh,
              paddleConfig.detBoxThresh == tierDefaults.boxThresh,
              paddleConfig.detUnclipRatio == tierDefaults.unclipRatio else { return false }
        // PaddleOCR-VL and the routing only matter to the engine that uses them.
        guard preset.engine == .auto else { return true }
        return vlConfig.variant == preset.vlVariant(current: vlConfig.variant)
            && vlConfig.maxOutputTokens == preset.vlOutputTokens
            && layeredConfig.escalateLowConfidence
            && layeredConfig.escalationConfidence == preset.escalationConfidence
    }

    /// Sets everything the preset stands for. What it does not stand for —
    /// languages, the page-handling switches, which content to read, export —
    /// is left as the user set it.
    func applyPreset(_ preset: QualityPreset) {
        ocrEngine = preset.engine
        var paddle = paddleConfig
        paddle.tier = preset.tier
        paddle.applyDetectionDefaults()
        paddle.detLimitSideLen = preset.detectionSide
        paddleConfig = paddle
        if preset.engine == .auto {
            var vl = vlConfig
            vl.variant = preset.vlVariant(current: vl.variant)
            vl.maxOutputTokens = preset.vlOutputTokens
            vlConfig = vl
            layeredConfig.escalateLowConfidence = true
            layeredConfig.escalationConfidence = preset.escalationConfidence
        }
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
    var mergeLineBreaks = false { didSet { persistSettings() } }
    /// 去除连续空行，只保留单个空行
    var removeEmptyLines = false { didSet { persistSettings() } }
    /// 去除每行首尾多余空格
    var trimWhitespace = true { didSet { persistSettings() } }
    /// 自动去除行内连字符换行（如 "exam-\nple" → "example"）
    var removeHyphenBreaks = false { didSet { persistSettings() } }

    // MARK: - Behavior settings
    /// 添加文件后自动开始识别
    var autoStartOnAdd = OCRSettings().autoStartOnAdd { didSet { persistSettings() } }
    /// 重新处理时跳过已完成的文件
    var skipCompleted = true { didSet { persistSettings() } }

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
    var exportSeparator: ExportSeparator = .emptyLine { didSet { persistSettings() } }
    /// 导出时包含文件名标题
    var exportIncludeFilename = true { didSet { persistSettings() } }

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

    var exportFormat: ExportFormat = .markdown { didSet { persistSettings() } }
    var exportLayout: ExportLayout = .combined { didSet { persistSettings() } }

    // MARK: - Result rendering settings
    /// Draw the figure and chart regions of the page in the Markdown pane,
    /// cropped from the source image, instead of a bare placeholder.
    var renderFigures = true { didSet { persistSettings() } }
    /// Draw recognised tables as a grid rather than as the HTML the model wrote.
    var renderTables = true { didSet { persistSettings() } }
    /// Write the figures out next to an exported Markdown file and point the
    /// document at them.
    var exportFigures = true { didSet { persistSettings() } }
    /// Leave running headers, footers and page numbers out of the document.
    ///
    /// This is a decision about the *document*, not about the recognition:
    /// those regions are always read and always drawn in the preview, so
    /// flipping this rebuilds what is already on screen instead of asking for
    /// another pass over the file.
    var dropPageFurniture = true {
        didSet {
            guard oldValue != dropPageFurniture else { return }
            persistSettings()
            rebuildDocuments()
        }
    }

    /// Flatten a photographed page before reading it — PaddleOCR's
    /// 图片扭曲矫正. Off by default, as upstream: a scan has nothing to flatten,
    /// and the model would only resample it.
    var useDocUnwarping = false {
        didSet {
            guard oldValue != useDocUnwarping else { return }
            if !useDocUnwarping { docUnwarper = nil; docUnwarperEnv = nil }
            persistSettings()
        }
    }

    /// Which auxiliary regions stay in the document. Everything not in here is
    /// filtered out, which is how PaddleOCR's own 辅助内容解析 switches read:
    /// off means "the model found it and left it out".
    var keptAuxiliary: Set<PPLayoutLabel> = Set(OCRSettings().keptAuxiliary.compactMap(PPLayoutLabel.init(rawName:))) {
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
        guard items[index].pages[page].blocks[blockIndex].isCorrected else {
            return rereadBlockNow(itemID: itemID, page: page, blockIndex: blockIndex)
        }
        prompt = UserPrompt(title: String(localized: "This region has manual edits"),
                            message: String(localized: "Rereading closely will replace the edited text."),
                            confirmation: .init(label: String(localized: "Reread")) { [weak self] in
                                self?.rereadBlockNow(itemID: itemID, page: page, blockIndex: blockIndex)
                            })
    }

    private func rereadBlockNow(itemID: UUID, page: Int, blockIndex: Int) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].pages.indices.contains(page),
              items[index].pages[page].blocks.indices.contains(blockIndex) else { return }
        let item = items[index]
        let block = item.pages[page].blocks[blockIndex]
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
                let output = try await BlockingWork.run {
                    try engine.recognize([VLRequest(image: image, crop: crop, task: task,
                                                    maxTokens: limit)])[0].get()
                }
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
    private(set) var rereadingPages: Set<PageRef> = []

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
        guard items[index].pages[page].blocks.contains(where: \.isCorrected) else {
            return rereadPageNow(itemID: itemID, page: page)
        }
        prompt = UserPrompt(title: String(localized: "Page \(page + 1) has manual edits"),
                            message: String(localized: "Recognizing this page again replaces these edits with the new result. Other pages are not affected."),
                            confirmation: .init(label: String(localized: "Recognize Again"), isDestructive: true) { [weak self] in
                                self?.rereadPageNow(itemID: itemID, page: page)
                            })
    }

    private func rereadPageNow(itemID: UUID, page: Int) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              canRereadPage(items[index]), items[index].pages.indices.contains(page) else { return }
        let item = items[index]
        let ref = PageRef(itemID: itemID, page: page)
        guard !rereadingPages.contains(ref) else { return }
        var settings = currentRecognitionSettings()
        if let engine = item.engine { settings.engine = engine }
        let url = item.url
        rereadingPages.insert(ref)

        Task {
            defer { rereadingPages.remove(ref) }
            do {
                let engines = try await loadEngines(for: settings)
                let result = try await DocumentRecognizer.recognize(page: page, of: url, settings: settings,
                                                                    engines: engines, isCancelled: { false },
                                                                    progress: nil)
                // The file may have been removed, or read again as a whole,
                // while this page was being read.
                guard let i = items.firstIndex(where: { $0.id == itemID }), items[i].status == .completed,
                      items[i].pages.indices.contains(page) else { return }
                items[i].pages[page] = result
                rebuildDocument(at: i)
                store.save(items[i])
            } catch {
                prompt = UserPrompt(title: String(localized: "Recognizing page \(page + 1) again failed"),
                                    message: error.localizedDescription)
            }
        }
    }

    // MARK: - Folder watching

    /// Watch a folder and read whatever lands in it.
    var watchEnabled = false {
        didSet { persistSettings(); if !isRestoringSettings { updateWatcher() } }
    }
    var watchFolder: URL? {
        didSet { persistSettings(); if !isRestoringSettings { updateWatcher() } }
    }
    /// Where a watched file's result is written, in the export format
    /// currently chosen. Nil keeps the results in the list only.
    var watchOutputFolder: URL? {
        didSet { persistSettings(); if !isRestoringSettings { updateWatcher() } }
    }

    private var watcher: FolderWatcher?
    /// Files the watcher added, exported as each one finishes.
    @ObservationIgnored private var watchedIDs = Set<UUID>()
    /// Watched files arrived while a run was going; they get one of their own
    /// when it ends.
    @ObservationIgnored private var watchBacklog = false

    var isWatching: Bool { watcher != nil }

    private func updateWatcher() {
        watcher?.stop()
        watcher = nil
        guard watchEnabled, !isRestoringQueue, let folder = watchFolder else { return }
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
                    return FileManager.default.fileExists(atPath: result.path(percentEncoded: false))
                }
            },
            onFiles: { [weak self] urls in self?.addWatched(urls, root: folder) })
        watcher?.start()
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
        if autoTranslate { watchedAwaitingTranslation.insert(item.id) }
    }

    // MARK: - Translation

    /// Translate each result as soon as it is recognized.
    var autoTranslate = false { didSet { persistSettings() } }
    /// The language results are translated into, automatically or not.
    var translationTarget = DocumentTranslation.defaultTarget { didSet { persistSettings() } }
    /// Results waiting to be translated, or being translated now.
    var translatingIDs: Set<UUID> = []
    /// Why the last automatic translation did not finish.
    var translationFailure: String?

    let translator = AutoTranslator()

    /// Watched files whose translation is still to be written out.
    @ObservationIgnored var watchedAwaitingTranslation = Set<UUID>()

    // MARK: - Capture shortcut

    /// Capture a screenshot with ⌥⇧⌘2 from any app, not only this one.
    var globalCaptureShortcut = true {
        didSet { persistSettings(); if !isRestoringSettings { updateCaptureShortcut() } }
    }
    /// True when another app already holds ⌥⇧⌘2.
    private(set) var captureShortcutTaken = false
    @ObservationIgnored private var captureHotKeys: [GlobalHotKey] = []

    /// Brings the main window to the front, opening one if it was closed —
    /// for a capture made from another app, or the menu bar. Set by the app.
    @ObservationIgnored var showMainWindow: (() -> Void)?

    private func updateCaptureShortcut() {
        captureHotKeys.forEach { $0.unregister() }
        captureHotKeys = []
        captureShortcutTaken = false
        guard globalCaptureShortcut else { return }
        let capture = GlobalHotKey.capture { [weak self] in self?.captureScreenshot() }
        if capture.register() { captureHotKeys.append(capture) } else { captureShortcutTaken = true }
    }

    // MARK: - Saving screenshots

    /// Where screenshots are saved; nil for the desktop.
    var screenshotFolder: URL? {
        didSet { persistSettings() }
    }
    var screenshotFormat = ScreenshotFormat.png {
        didSet { persistSettings() }
    }
    var savesPagesAsPDF = true {
        didSet { persistSettings() }
    }
    /// Where a screenshot saved now goes.
    var screenshotDestination: URL {
        screenshotFolder ?? URL.desktopDirectory
    }

    // MARK: - Presence

    /// A small round button above every other window that captures on click.
    var showFloatingButton = false {
        didSet { persistSettings(); if !isRestoringSettings { updatePresence() } }
    }
    @ObservationIgnored private var floatingButton: FloatingCaptureButton?

    private func updatePresence() {
        if showFloatingButton {
            if floatingButton == nil { floatingButton = FloatingCaptureButton(model: self) }
        } else {
            floatingButton?.close()
            floatingButton = nil
        }
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

    /// What the file picker offers: every readable file, and folders.
    nonisolated static let importableTypes: [UTType] =
        supportedExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]

    /// The main window's file picker is showing.
    var isImportingFiles = false

    /// Adds files, and everything readable inside folders — subfolders
    /// included. Each file found in a folder remembers that folder, so an
    /// export can lay the results out the way the sources were.
    func addImages(urls: [URL]) {
        Task {
            add(await BlockingWork.run { Self.expand(urls) })
        }
    }

    /// Walks folders on a background thread: a folder of a few thousand scans
    /// should not freeze the window while it is listed.
    nonisolated private static func expand(_ urls: [URL]) -> [(url: URL, root: URL?)] {
        var found: [(url: URL, root: URL?)] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { continue }
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
            inFolder.sort { $0.path(percentEncoded: false).localizedStandardCompare($1.path(percentEncoded: false)) == .orderedAscending }
            found += inFolder.map { ($0, url) }
        }
        return found
    }

    func add(_ files: [(url: URL, root: URL?)]) {
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
        // Only what was just added: a run started here used to pick up every
        // pending file, and one already under way ignored the new ones.
        if autoStartOnAdd {
            recognize(ids: Set(uniqueNew.map(\.id)))
        }
    }

    /// Makes the file list's pictures in the background, a few at a time.
    ///
    /// Decoding every added image in full on the main thread — what the list
    /// used to do to get a thumbnail — froze the window for a folder of
    /// photos and held each one in memory for as long as it stayed listed.
    func loadThumbnails(for ids: [UUID]) {
        let targets = items.filter { ids.contains($0.id) }.map { ($0.id, $0.url) }
        Task { [weak self] in
            for start in stride(from: 0, to: targets.count, by: 16) {
                let chunk = Array(targets[start..<min(start + 16, targets.count)])
                let made = await BlockingWork.run {
                    chunk.compactMap { id, url in
                        PageImages.thumbnail(of: url).map { (id, ImageItem.page(from: $0)) }
                    }
                }
                guard let self else { return }
                for (id, image) in made {
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        items[index].thumbnail = image
                    }
                }
            }
        }
    }

    // MARK: - Screenshot

    /// From the moment capture is asked for until the picture is taken or
    /// the user gives up, so a second press does not start a second one.
    var isCapturing = false
    /// Files asked to be read while a run was busy — screenshots, files
    /// added with 「添加后自动识别」 on, 「开始识别」 from the list — read once
    /// it ends.
    @ObservationIgnored private var waitingForRun = Set<UUID>()

    /// Macros the user recorded, to do again.
    let macros: MacroLibrary
    /// The macro shown in the Recorded Actions window.
    var selectedMacroID: UUID?
    /// A recording under way: a screenshot taken now is a step of it.
    @ObservationIgnored var activeRecording: MacroRecording?
    /// The macro being done again, while it is.
    var runningMacroID: UUID?
    /// Opens the Recorded Actions window. Set by the app.
    @ObservationIgnored var showMacros: (() -> Void)?

    /// Lets the user drag out a part of the screen or click a window, then
    /// asks what to do with it: copy it, save it, recognize its text, or
    /// scroll on for a long screenshot.
    func captureScreenshot() {
        // While recording, the user's usual way to take a screenshot marks
        // where the macro captures.
        if let activeRecording {
            Task { await activeRecording.captureHere() }
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            // The held screen stays while the bar is up over it: no flash of
            // the live screen between the two, and nothing beneath answers
            // until the user has chosen what to do.
            guard let taken = await ScreenCapture.choose(lingering: true),
                  let area = ScreenCapture.frame(of: taken.target) else {
                await CaptureOverlay.closeLingering()
                return
            }
            var images = [taken.image]
            let pixelsPerPoint = ScreenCapture.pixelsPerPoint(of: taken.target)
            var finish = await CaptureBar.choose(around: area)
            if finish == .longCapture {
                // Scrolling needs the live screen: it goes once the long
                // screenshot's own marks are up over it — straight away when
                // a permission is asked for first, so the question is seen.
                if InputControl.isAllowedQuietly {
                    Task { await CaptureOverlay.closeLingering() }
                } else {
                    await CaptureOverlay.closeLingering()
                }
                let (parts, picked) = await ScrollingCapture().run(taken.target, first: taken.image)
                if !parts.isEmpty { images = parts }
                finish = picked
            } else {
                // Recognizing shows OCRFlow's window: it stays in front.
                await CaptureOverlay.closeLingering(givingBack: finish != .recognize)
            }
            switch finish {
            case .recognize: recognizeCaptures(images, pixelsPerPoint: pixelsPerPoint)
            case .copy: copyCaptures(images, pixelsPerPoint: pixelsPerPoint)
            case .save: saveCaptures(images, pixelsPerPoint: pixelsPerPoint)
            case .cancel, .longCapture, .done: break
            }
        }
    }

    /// Into the list, and read.
    private func recognizeCaptures(_ images: [CGImage], pixelsPerPoint: CGFloat) {
        let names = Self.numberedNames(String(localized: "Screenshot \(Self.captureDate())"), count: images.count)
        let files = zip(images, names).compactMap { image, name -> URL? in
            let url = newCaptureURL(named: name, extension: "png")
            return ScreenshotFormat.png.write(image, to: url, pixelsPerPoint: pixelsPerPoint) ? url : nil
        }
        guard !files.isEmpty else { return }
        // Taken from another app: the result is what the user is waiting
        // to see.
        showMainWindow?()
        addCaptures(files)
    }

    /// At the size it looks on screen, as PNG for apps that take it and as a
    /// picture for the rest.
    private func copyCaptures(_ images: [CGImage], pixelsPerPoint: CGFloat) {
        guard let image = images.first else { return }
        let picture = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / pixelsPerPoint,
                                                          height: CGFloat(image.height) / pixelsPerPoint))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([picture])
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        HUDPanel.toast(String(localized: "Copied"))
    }

    /// Into the screenshots folder of the settings — the desktop unless
    /// changed — with nothing to ask. A very long picture in parts is
    /// numbered.
    private func saveCaptures(_ images: [CGImage], pixelsPerPoint: CGFloat) {
        let folder = screenshotDestination
        let names = Self.numberedNames(String(localized: "Screenshot \(Self.captureDate())"), count: images.count)
        let format = screenshotFormat
        var saved: [URL] = []
        for (image, name) in zip(images, names) {
            let url = Self.freeURL(in: folder, named: name, extension: format.pathExtension)
            if format.write(image, to: url, pixelsPerPoint: pixelsPerPoint) { saved.append(url) }
        }
        reportSaved(saved, in: folder)
    }

    /// Said briefly, where they went.
    func reportSaved(_ files: [URL], in folder: URL) {
        if files.isEmpty {
            HUDPanel.toast(String(localized: "Could not save the screenshot"))
        } else {
            HUDPanel.toast(String(localized: "Saved to “\(FileManager.default.displayName(atPath: folder.path(percentEncoded: false)))”"))
        }
    }

    /// Screenshots taken one after another until Escape: dragging takes an
    /// area, everything else works as usual. What becomes of them is asked
    /// at the end.
    func queueScreenshots() {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            let pages = await QueueCapture().run()
            isCapturing = false
            guard let folder = pages.first?.deletingLastPathComponent() else { return }
            defer { try? FileManager.default.removeItem(at: folder) }
            let options: [ResultChoice.Option] = pages.count > 1
                ? [.recognizeTogether, .recognizeEach, .save, .discard] : [.recognize, .save, .discard]
            let title = pages.count > 1 ? String(localized: "\(pages.count) screenshots taken. What becomes of them?")
                : String(localized: "1 screenshot taken. What becomes of it?")
            switch await ResultChoice.ask(title, options: options) {
            case .recognizeTogether:
                deliver(await captureFiles(from: pages, as: .document, named: nil))
            case .recognizeEach, .recognize:
                deliver(await captureFiles(from: pages, as: .images, named: nil))
            case .save:
                let folder = screenshotDestination
                reportSaved(await captureFiles(from: pages, as: .document, named: nil, into: folder), in: folder)
            case .discard:
                break
            }
        }
    }

    /// Into the list, shown, and read.
    func deliver(_ files: [URL]) {
        guard !files.isEmpty else { return }
        showMainWindow?()
        addCaptures(files)
    }

    /// Puts what was captured — one picture a file — together: as one
    /// document, one long picture (or a few, for a very long one) or a file
    /// each. The files given are left where they are.
    ///
    /// Into the library's screenshots folder, to be read, or, given a
    /// `folder`, saved there as the settings say: pictures in the chosen
    /// format, a document as one PDF or a picture a page.
    /// `name` heads the file names; by default they say what they are.
    /// Several of one kind are numbered in the order they were taken.
    func captureFiles(from pages: [URL], as output: Macro.Output, named name: String?,
                      into folder: URL? = nil) async -> [URL] {
        guard !pages.isEmpty else { return [] }
        let date = Self.captureDate()
        func label(_ fallback: String) -> String { name.map { "\($0) \(date)" } ?? fallback }
        func labels(_ fallback: String, count: Int) -> [String] { Self.numberedNames(label(fallback), count: count) }
        func destination(_ label: String, _ pathExtension: String) -> URL {
            folder.map { Self.freeURL(in: $0, named: label, extension: pathExtension) }
                ?? newCaptureURL(named: label, extension: pathExtension)
        }
        let format = screenshotFormat
        /// To be read, as it is; to be saved, in the format of the settings.
        func copy(_ page: URL, _ label: String) -> URL? {
            guard folder != nil else {
                let url = destination(label, page.pathExtension)
                return (try? FileManager.default.copyItem(at: page, to: url)) == nil ? nil : url
            }
            guard let image = PageImages.wholeImage(at: page) else { return nil }
            return write(image, label, pixelsPerPoint: ScreenshotFormat.pixelsPerPoint(of: page))
        }
        func write(_ image: CGImage, _ label: String, pixelsPerPoint: CGFloat) -> URL? {
            let url = destination(label, folder == nil ? "png" : format.pathExtension)
            let written = (folder == nil ? ScreenshotFormat.png : format).write(image, to: url, pixelsPerPoint: pixelsPerPoint)
            return written ? url : nil
        }
        func copies(_ pages: [URL]) -> [URL] {
            zip(pages, labels(String(localized: "Screenshot \(date)"), count: pages.count)).compactMap(copy)
        }
        switch output {
        case .images:
            return copies(pages)
        case .longImage where pages.count > 1:
            let joined = await Task.detached { [pages] in ScrollStitcher.stitch(pages) }.value
            if let joined {
                let pixelsPerPoint = ScreenshotFormat.pixelsPerPoint(of: pages[0])
                return zip(joined, labels(String(localized: "Long Screenshot \(date)"), count: joined.count)).compactMap {
                    write($0, $1, pixelsPerPoint: pixelsPerPoint)
                }
            }
            // Not one scrolled view after all: pages, then.
            return await captureFiles(from: pages, as: .document, named: name, into: folder)
        case .document, .longImage:
            if pages.count == 1, folder == nil || LongImagePages.pages(of: pages[0]) == nil {
                return [copy(pages[0], label(String(localized: "Screenshot \(date)")))].compactMap { $0 }
            }
            if folder != nil, !savesPagesAsPDF {
                return copies(pages)
            }
            // A long picture among them is cut into pages of a usual shape,
            // as it would be read.
            let scratch = URL.temporaryDirectory.appending(path: "OCRFlow Cut \(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let cut = Self.cuttingLongPages(pages, into: scratch)
            if let folder {
                let url = Self.freeURL(in: folder, named: label(String(localized: "Queue Screenshots \(date)")), extension: "pdf")
                return Self.writePDF(of: cut, to: url) ? [url] : []
            }
            let url = newCaptureURL(named: label(String(localized: "Queue Screenshots \(date)")), extension: "tiff")
            return ScrollingCapture.assemble(cut, into: url) ? [url] : []
        }
    }

    /// The pages, with any long one in pages of a usual shape, written into
    /// `scratch`.
    private nonisolated static func cuttingLongPages(_ pages: [URL], into scratch: URL) -> [URL] {
        pages.flatMap { page -> [URL] in
            guard let cuts = LongImagePages.pages(of: page), cuts.count > 1 else { return [page] }
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let pixelsPerPoint = ScreenshotFormat.pixelsPerPoint(of: page)
            return cuts.indices.compactMap { index in
                guard let image = LongImagePages.page(index, of: page, cutAt: cuts) else { return nil }
                let url = scratch.appending(path: "\(UUID().uuidString).png")
                return ScreenshotFormat.png.write(image, to: url, pixelsPerPoint: pixelsPerPoint) ? url : nil
            }
        }
    }

    /// A PDF of the pictures, a page each, at the size they were on screen.
    private nonisolated static func writePDF(of pages: [URL], to url: URL) -> Bool {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { return false }
        for page in pages {
            guard let image = PageImages.wholeImage(at: page) else { continue }
            let scale = ScreenshotFormat.pixelsPerPoint(of: page)
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// `base` for one; for several, `base` numbered from 1 in order, the
    /// numbers as wide as the last so they sort as taken.
    nonisolated static func numberedNames(_ base: String, count: Int) -> [String] {
        guard count > 1 else { return [base] }
        let digits = String(count).count
        return (1...count).map { "\(base) \(String(format: "%0\(digits)d", $0))" }
    }

    /// A name not taken yet in `folder`, which is made if need be.
    nonisolated static func freeURL(in folder: URL, named name: String, extension pathExtension: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appending(component: name).appendingPathExtension(pathExtension)
        var count = 1
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            count += 1
            url = folder.appending(component: "\(name) \(count)").appendingPathExtension(pathExtension)
        }
        return url
    }

    /// The time in a file name: sortable, and with no colons, which Finder
    /// shows as slashes.
    private static func captureDate() -> String {
        let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)
        let format: Date.FormatString =
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: hour).\(minute: .twoDigits).\(second: .twoDigits)"
        return Date.now.formatted(.verbatim(format, timeZone: .current, calendar: Calendar(identifier: .gregorian)))
    }

    /// In the library folder, so the entry in the list keeps working after a
    /// relaunch. Numbered when there are several in one second, as there are
    /// when taking page after page.
    private func newCaptureURL(named name: String, extension pathExtension: String) -> URL {
        Self.freeURL(in: store.directory.appending(path: "Screenshots", directoryHint: .isDirectory),
                     named: name, extension: pathExtension)
    }

    /// Adds captures to the list, selected, and reads them.
    func addCaptures(_ urls: [URL]) {
        let before = Set(items.map(\.id))
        add(urls.map { ($0, nil) })
        let new = Set(items.filter { !before.contains($0.id) }.map(\.id))
        guard !new.isEmpty else { return }
        selectedIDs = new
        recognize(ids: new, useCache: false)
    }

    /// Asks the main window to show the file picker.
    func openFilePicker() {
        isImportingFiles = true
    }

    func removeItem(id: UUID) {
        removeItems(ids: [id])
    }

    func removeSelectedItems() {
        removeItems(ids: selectedIDs)
    }

    func removeItems(ids: Set<UUID>) {
        if !selectedIDs.isDisjoint(with: ids) {
            selectedIDs = Self.neighbour(afterRemoving: ids, from: items.map(\.id)).map { [$0] } ?? []
        }
        for item in items where ids.contains(item.id) && item.status != .processing {
            if let key = item.resume?.key { store.removePartial(for: key) }
        }
        items.removeAll { ids.contains($0.id) }
        forgetTranslations(ids)
        recalcProgress()
        store.remove(Array(ids))
        store.saveQueue(items)
    }

    /// What stays selected once `removed` are gone, the way Finder and Mail
    /// do it: the item just after them, or at the end of the list the one
    /// just before.
    nonisolated static func neighbour(afterRemoving removed: Set<UUID>, from order: [UUID]) -> UUID? {
        guard let first = order.firstIndex(where: removed.contains),
              let last = order.lastIndex(where: removed.contains) else { return nil }
        return order[(last + 1)...].first { !removed.contains($0) }
            ?? order[..<first].last { !removed.contains($0) }
            ?? order.first { !removed.contains($0) }
    }

    func clearAll() {
        store.remove(items.map(\.id))
        store.prunePartials(keeping: [])
        forgetTranslations(Set(items.map(\.id)))
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
    private(set) var runStartedAt: Date?

    func startProcessing() {
        let ids = items.filter(isActionable).map(\.id)
        // A completed file is only actionable when 「跳过已完成」 is off, and
        // running it again would throw away any corrections made to it.
        let corrected = items.filter { ids.contains($0.id) && $0.isCorrected }
        confirmDiscardingCorrections(in: corrected) { [weak self] in
            self?.run(ids: ids, useCache: true)
        }
    }

    /// Re-arms the given items and runs them immediately. A 「重试」 that only
    /// flipped the badge back to pending and waited for a separate
    /// 「开始识别」 read as though nothing had happened.
    ///
    /// Asking to read a file again means reading it again: the recognition
    /// cache is bypassed.
    func retryItems(ids: Set<UUID>) {
        let corrected = items.filter { ids.contains($0.id) && $0.isCorrected }
        confirmDiscardingCorrections(in: corrected) { [weak self] in
            guard let self else { return }
            for id in ids { retryItem(id: id) }
            run(ids: items.filter { ids.contains($0.id) }.map(\.id), useCache: false)
        }
    }

    /// Hand corrections are the one thing a re-run cannot reproduce, so they
    /// are never thrown away without asking. Runs `action` straight away when
    /// there are none, and once the user agrees when there are.
    private func confirmDiscardingCorrections(in corrected: [ImageItem], then action: @escaping () -> Void) {
        guard !corrected.isEmpty else { return action() }
        prompt = UserPrompt(title: corrected.count == 1
                                ? String(localized: "“\(corrected[0].fileName)” has manual edits")
                                : String(localized: "\(corrected.count) files have manual edits"),
                            message: String(localized: "Recognizing again will replace these edits with new results. Export first to keep them."),
                            confirmation: .init(label: String(localized: "Recognize Again"), isDestructive: true,
                                                action: action))
    }

    func run(ids: [UUID], useCache: Bool) {
        guard !isProcessing, !isStopping, !ids.isEmpty else { return }
        isProcessing = true
        runStartedAt = Date()
        cancellation.reset()

        Task {
            await processConcurrently(ids, useCache: useCache)
            isProcessing = false
            isStopping = false
            runStartedAt = nil
            // Files the watcher found, and files asked for, while this run
            // was busy.
            let watched = watchBacklog ? watchedIDs : []
            watchBacklog = false
            let waiting = items.filter {
                (watched.contains($0.id) || waitingForRun.contains($0.id)) && $0.status == .pending
            }.map(\.id)
            waitingForRun.removeAll()
            run(ids: waiting, useCache: true)
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

    /// Reads the given files now, or as soon as the run in progress ends.
    /// Files already read are left alone; 「重新识别」 is for those.
    func recognize(ids: Set<UUID>, useCache: Bool = true) {
        let pending = items.filter { ids.contains($0.id) && $0.status == .pending }.map(\.id)
        guard !pending.isEmpty else { return }
        if isProcessing || isStopping {
            waitingForRun.formUnion(pending)
        } else {
            run(ids: pending, useCache: useCache)
        }
    }

    /// The engine a single file is being read with when it is not the one
    /// selected in the settings — 「用 PaddleOCR-VL 重新识别」 on one file
    /// leaves every other file, and the setting itself, as they were. Kept
    /// across a stop, so carrying the file on reads the rest the same way.
    @ObservationIgnored private var engineOverrides: [UUID: OCREngine] = [:]

    /// Whether 「用 PaddleOCR-VL 重新识别」 applies to this file.
    func canReadWithVL(_ item: ImageItem) -> Bool {
        item.status != .processing && VLModelStore.isInstalled(vlConfig.variant)
            && !(item.status == .completed && item.engine == .paddleVL)
    }

    /// Reads one file again with PaddleOCR-VL alone, whatever engine is
    /// selected.
    func readWithVL(id: UUID) {
        guard !isProcessing, let item = items.first(where: { $0.id == id }) else { return }
        confirmDiscardingCorrections(in: item.isCorrected ? [item] : []) { [weak self] in
            guard let self else { return }
            engineOverrides[id] = .paddleVL
            retryItem(id: id)
            run(ids: [id], useCache: false)
        }
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
            let prepared = await BlockingWork.run {
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
            }

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
                let pages = try await DocumentRecognizer.recognize(
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
                outcome = (pages, false)
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
            items[i] = updated          // one assignment, one change
            engineOverrides[id] = nil
            if let resumeKey { store.removePartial(for: resumeKey) }
            store.save(updated, isNewReading: true)
            store.saveQueue(items)
            exportIfWatched(updated)
            if autoTranslate { translate(updated) }
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
    @ObservationIgnored private var engineLoading: Task<DocumentRecognizer.Engines, Error>?

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
        if settings.engine == .auto || settings.engine == .paddleVL {
            engines.orienter = await loadDocOrienter(for: settings.paddleConfig)
        }
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
        let engine = try await BlockingWork.run {
            try VLEngine(config: config)
        }
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
                vlLayoutSession = try await BlockingWork.run {
                    try PPSession(modelPath: modelURL, env: env, config: .default)
                }
            }
            detector = vlLayoutSession.map(PPLayoutDetector.init)
        }

        return VLDocumentPipeline(layout: detector, vl: engine)
    }

    /// Loads the page orientation classifier when the setting asks for it.
    /// It is small and bundled; failing to load it only means pages are read
    /// as they lie.
    private func loadDocOrienter(for config: PPOCRConfig) async -> PPDocOrientationClassifier? {
        guard config.useDocOrientation else { return nil }
        if let docOrienter { return docOrienter }
        guard let url = try? PPModelStore.resolveDocOrientationModel(),
              let env = try? ORTEnv(loggingLevel: .error) else { return nil }
        let session = try? await BlockingWork.run {
            try PPSession(modelPath: url, env: env, config: .default)
        }
        guard let session else { return nil }
        docOrienterEnv = env
        docOrienter = PPDocOrientationClassifier(session: session)
        return docOrienter
    }

    /// Loads UVDoc if the setting asks for it and the file is there. A missing
    /// model is not an error: the page is simply read as photographed.
    private func loadDocUnwarper() async -> PPDocUnwarper? {
        guard useDocUnwarping, PPModelStore.isUnwarpingModelInstalled else { return nil }
        if let docUnwarper { return docUnwarper }
        guard let url = try? PPModelStore.resolveUnwarpingModel(),
              let env = try? ORTEnv(loggingLevel: .error) else { return nil }
        let session = try? await BlockingWork.run {
            try PPSession(modelPath: url, env: env, config: .default)
        }
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
        let engine = try await BlockingWork.run {
            try PPOCREngine(config: config)
        }
        paddleEngine = engine
        return engine
    }

    // MARK: - Text post-processing

    func postProcess(_ raw: String) -> String {
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
            text.replace(/\n{3,}/, with: "\n\n")
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
    func recalcProgress() {
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

/// What the main window asks or tells the user on the view model's behalf.
struct UserPrompt: Identifiable {
    struct Confirmation {
        var label: String
        var isDestructive = false
        var action: () -> Void
    }

    let id = UUID()
    var title: String
    var message: String?
    /// The action being asked about. Nil for something only to be read.
    var confirmation: Confirmation?
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
