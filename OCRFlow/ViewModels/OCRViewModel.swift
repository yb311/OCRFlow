import Foundation
import AppKit
import Vision
import Combine
import UniformTypeIdentifiers
import OnnxRuntimeBindings

// MARK: - OCR Engine

enum OCREngine: String, CaseIterable, Identifiable, Codable {
    case visionFast     = "vision_fast"
    case visionAccurate = "vision_accurate"
    case paddleOCR      = "paddle_ocr"
    case paddleVL       = "paddle_vl"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .visionFast:     return "Apple Vision · 快速模式"
        case .visionAccurate: return "Apple Vision · 精准模式"
        case .paddleOCR:      return "PaddleOCR · PP-OCRv6"
        case .paddleVL:       return "PaddleOCR-VL · 1.6"
        }
    }

    var hint: String {
        switch self {
        case .visionFast:     return "速度快，适合批量快速处理"
        case .visionAccurate: return "识别效果好，速度稍慢"
        case .paddleOCR:      return "PP-OCRv6 模型，单模型覆盖 50 种语言，输出逐行文本框与置信度"
        case .paddleVL:       return "0.9B 视觉语言模型，版面分析 + 逐块识别，输出 Markdown（较慢，需下载模型）"
        }
    }

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
    var engine: OCREngine = .paddleOCR
    var recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]
    var maxConcurrentTasks: Int = OCRViewModel.defaultConcurrency
    var showTextBoxes = true
    var paddle: PPOCRConfig = .default
    var vl: VLConfig = .default
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

    init() {
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
            MainActor.assumeIsolated { self?.releaseVLEngine() }
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
                    useDocUnwarping: useDocUnwarping)
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
    }

    func resetAllSettings() {
        apply(OCRSettings())
        validateModelSelections()
        persistSettings()
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
        case emptyLine  = "空行"
        case divider    = "分割线"
        case pageBreak  = "换页符"
        case none       = "无"
        var id: String { rawValue }
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

        var id: String { rawValue }

        var label: String {
            switch self {
            case .markdown:  return "Markdown"
            case .plainText: return "纯文本"
            case .json:      return "JSON（含坐标与置信度）"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown:  return "md"
            case .plainText: return "txt"
            case .json:      return "json"
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
            case .combined: return "合并为一个文件"
            case .separate: return "每个文件单独导出"
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

    /// The document in pieces that remember which region each came from, for
    /// the rendered view. Falls back to one nameless piece for a result with no
    /// regions behind it.
    func documentFragments(for item: ImageItem) -> [PPDocumentAssembler.Fragment] {
        guard !item.layoutBlocks.isEmpty, item.derivesFromBlocks else {
            return [PPDocumentAssembler.Fragment(source: nil, markdown: item.markdown)]
        }
        return PPDocumentAssembler.fragments(from: item.layoutBlocks,
                                             dropping: droppedLabels,
                                             source: item.blockSource,
                                             inferHeadingLevels: vlConfig.inferHeadingLevels)
    }

    /// Replaces what the model read out of one region.
    ///
    /// The model gets a word wrong now and then, and the alternative to fixing
    /// it here is fixing it in the exported file — where the correction is lost
    /// the next time the file is exported. Editing the region itself means the
    /// document, the plain text and every future export all carry it.
    func correctBlock(itemID: UUID, blockIndex: Int, text: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].layoutBlocks.indices.contains(blockIndex),
              items[index].layoutBlocks[blockIndex].text != text else { return }
        items[index].layoutBlocks[blockIndex].text = text
        rebuildDocument(at: index)
    }

    /// Rebuilds the text and the Markdown of every result that still has the
    /// blocks it was assembled from.
    func rebuildDocuments() {
        for index in items.indices where items[index].derivesFromBlocks {
            rebuildDocument(at: index)
        }
    }

    private func rebuildDocument(at index: Int) {
        let item = items[index]
        guard item.derivesFromBlocks else { return }
        let recognition = Recognition(lines: item.textLines, blocks: item.layoutBlocks,
                                      blockSource: item.blockSource)
        let assembled = Self.assemble(recognition, dropping: droppedLabels,
                                      inferHeadingLevels: vlConfig.inferHeadingLevels)
        items[index].ocrText = postProcess(assembled.text)
        items[index].markdown = assembled.markdown
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

    /// How many files each export command would actually write, which is what
    /// the export menu's items are labelled and enabled by.
    var exportableCount: Int { items.filter(\.isExportable).count }
    var exportableSelectedCount: Int { selectedItems.filter(\.isExportable).count }

    // MARK: - File import

    func addImages(urls: [URL]) {
        let supported: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "webp", "pdf"]
        // Compared after resolving symlinks: /tmp and /private/tmp name the same
        // file, and a picker and a drag can hand back different spellings of it.
        var seen = Set(items.map { $0.url.resolvingSymlinksInPath().standardizedFileURL })
        var uniqueNew: [ImageItem] = []
        for url in urls where supported.contains(url.pathExtension.lowercased()) {
            // `seen` grows as we go, so a batch containing the same file twice
            // — an expanded folder overlapping a loose file, say — adds it once.
            guard seen.insert(url.resolvingSymlinksInPath().standardizedFileURL).inserted else { continue }
            uniqueNew.append(ImageItem(url: url))
        }
        items.append(contentsOf: uniqueNew)
        if selectedIDs.isEmpty, let first = uniqueNew.first { selectedIDs = [first.id] }
        recalcProgress()
        if autoStartOnAdd && !uniqueNew.isEmpty {
            Task { @MainActor in self.startProcessing() }
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heif, .webP, .pdf,
                                     UTType(filenameExtension: "heic") ?? .heif]
        panel.message = "选择图片文件或文件夹"
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            let urls = panel.urls.flatMap { url -> [URL] in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    return (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil)) ?? []
                }
                return [url]
            }
            addImages(urls: urls)
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
        items.removeAll { ids.contains($0.id) }
        recalcProgress()
    }

    func clearAll() {
        items.removeAll()
        selectedIDs = []
        totalProgress = 0
        isProcessing = false
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

    func startProcessing() {
        run(ids: items.filter(isActionable).map(\.id))
    }

    /// Re-arms the given items and runs them immediately. A 「重试」 that only
    /// flipped the badge back to pending and waited for a separate
    /// 「开始识别」 read as though nothing had happened.
    func retryItems(ids: Set<UUID>) {
        for id in ids { retryItem(id: id) }
        run(ids: items.filter { ids.contains($0.id) }.map(\.id))
    }

    private func run(ids: [UUID]) {
        guard !isProcessing, !isStopping, !ids.isEmpty else { return }
        isProcessing = true
        cancellation.reset()

        Task {
            await processConcurrently(ids)
            isProcessing = false
            isStopping = false
        }
    }

    /// Runs up to `maxConcurrentTasks` images at once instead of waiting for
    /// each to finish before starting the next. `processItem` moves decoding
    /// and recognition off the main actor, so several images really do make
    /// progress at the same time; PaddleOCR's own engine still finishes one
    /// recognition before starting the next — it serialises internally to
    /// avoid oversubscribing the CPU — but its decode step no longer sits idle
    /// while that happens, and Vision benefits in full.
    private func processConcurrently(_ ids: [UUID]) async {
        var iterator = ids.makeIterator()
        // PaddleOCR-VL holds a single llama context with one KV cache, so extra
        // workers would only queue up behind its lock while each one pinned a
        // decoded page in memory.
        let ceiling = ocrEngine == .paddleVL ? 1 : maxConcurrentTasks
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
                    await self?.processItem(id: id)
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
        }
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
            let stem = (targets[0].fileName as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(stem)_OCR.\(format.fileExtension)"
            panel.message = "导出「\(targets[0].fileName)」的识别结果"
        } else {
            panel.nameFieldStringValue = "OCRFlow_Results.\(format.fileExtension)"
            panel.message = "导出 \(targets.count) 个文件的识别结果（合并为一个文件）"
        }
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if format == .json {
            let payload = targets.map { Self.exportPayload(for: $0) }
            try? Self.jsonData(payload).write(to: url)
            return
        }

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

    /// One file per image, into a folder the user picks. A batch of scans is
    /// usually wanted as a batch of documents, not as one long one.
    private func exportSeparately(_ targets: [ImageItem], format: ExportFormat) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择导出位置，\(targets.count) 个文件将各自保存为 .\(format.fileExtension)"
        panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var used = Set<String>()
        for item in targets {
            let stem = (item.fileName as NSString).deletingPathExtension
            var name = "\(stem)_OCR"
            var suffix = 2
            // Two source files can share a stem — `scan.png` and `scan.pdf` —
            // and the second must not overwrite the first.
            while !used.insert(name).inserted {
                name = "\(stem)_OCR-\(suffix)"
                suffix += 1
            }
            let url = folder.appendingPathComponent("\(name).\(format.fileExtension)")
            if format == .json {
                try? Self.jsonData([Self.exportPayload(for: item)]).write(to: url)
            } else {
                let body = self.body(of: item, format: format, alongside: url)
                let text = exportIncludeFilename && format == .markdown
                    ? "# \(item.fileName)\n\n\(body)"
                    : body
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        NSWorkspace.shared.open(folder)
    }

    private func body(of item: ImageItem, format: ExportFormat, alongside file: URL) -> String {
        switch format {
        case .plainText, .json:
            return item.ocrText
        case .markdown:
            guard item.hasMarkdown else { return item.ocrText }
            guard exportFigures else { return item.markdown }
            return Self.writingFigures(of: item, from: item.markdown, alongside: file)
        }
    }

    private static func contentType(for format: ExportFormat) -> UTType {
        switch format {
        case .markdown:  return UTType(filenameExtension: "md") ?? .plainText
        case .plainText: return .plainText
        case .json:      return .json
        }
    }

    // MARK: - JSON export

    /// The structured result, in the shape the rest of the world can read:
    /// every line with its box and confidence, every layout region with its
    /// label and its place in the reading order.
    private struct ExportedPage: Encodable {
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
        }
        var file: String
        var engine: String?
        var width: Double
        var height: Double
        var text: String
        var markdown: String?
        var lines: [Line]
        var regions: [Region]
    }

    private static func exportPayload(for item: ImageItem) -> ExportedPage {
        let size = item.pixelSize
        return ExportedPage(
            file: item.fileName,
            engine: item.engine?.rawValue,
            width: size.width, height: size.height,
            text: item.ocrText,
            markdown: item.hasMarkdown ? item.markdown : nil,
            lines: item.textLines.map { line in
                ExportedPage.Line(text: line.text, confidence: line.confidence,
                                  quad: line.quad.map { [Double($0.x), Double($0.y)] })
            },
            regions: item.layoutBlocks.map { block in
                ExportedPage.Region(label: block.label.rawName,
                                    readingOrder: block.readingOrder,
                                    score: block.score,
                                    box: [Double(block.rect.minX), Double(block.rect.minY),
                                          Double(block.rect.width), Double(block.rect.height)],
                                    text: block.text,
                                    isPageFurniture: block.label.isPageFurniture)
            })
    }

    private static func jsonData(_ pages: [ExportedPage]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(pages)) ?? Data()
    }

    /// Saves the figures a document points at into a folder beside the exported
    /// file and rewrites the placeholders to reference them.
    ///
    /// Without this the `![图片]()` placeholders leave the export with broken
    /// images: the pictures only exist inside the source page. Figures the crop
    /// could not be taken from — a PDF's later pages, whose blocks are not kept
    /// — keep their empty placeholder.
    private static func writingFigures(of item: ImageItem, from markdown: String,
                                       alongside file: URL) -> String {
        let crops = DocumentFigures.crops(for: item)
        guard crops.contains(where: { $0 != nil }) else { return markdown }

        let stem = file.deletingPathExtension().lastPathComponent
        let folderName = "\(stem).assets"
        let folder = file.deletingLastPathComponent().appendingPathComponent(folderName)
        guard (try? FileManager.default.createDirectory(at: folder,
                                                        withIntermediateDirectories: true)) != nil
        else { return markdown }

        let prefix = sanitizedFileStem((item.fileName as NSString).deletingPathExtension)
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

    private func processItem(id: UUID) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .processing
        items[idx].processingProgress = 0

        let url = items[idx].url
        let settings = currentRecognitionSettings()
        let cancelToken = cancellation

        let reportProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].processingProgress = value
                self.recalcProgress()
            }
        }

        do {
            var paddleEngine: PPOCREngine?
            var vlPipeline: VLDocumentPipeline?
            let unwarper = await loadDocUnwarper()
            switch settings.engine {
            case .paddleOCR:
                paddleEngine = try await loadPaddleEngine(for: settings.paddleConfig)
            case .paddleVL:
                vlPipeline = try await loadVLPipeline(for: settings.vlConfig)
            case .visionFast, .visionAccurate:
                break
            }

            // Decoding and recognition run entirely off the main actor, so
            // several images make real progress at once when `startProcessing`
            // fans a batch out across a task group, instead of each one
            // blocking the actor in turn.
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.recognizeDocument(at: url, settings: settings, paddleEngine: paddleEngine,
                                           vlPipeline: vlPipeline, unwarper: unwarper,
                                           isCancelled: { cancelToken.isCancelled },
                                           progress: reportProgress)
            }.value

            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            // The engines answer a cancellation by returning early, so a
            // stopped run comes back like any other — just with part of the
            // page missing. Saving that as a result is what made a stopped
            // newspaper look like a page of nothing but image placeholders.
            guard !cancelToken.isCancelled else {
                var stopped = items[i]
                stopped.clearResults()
                stopped.status = .cancelled
                items[i] = stopped
                return
            }
            var updated = items[i]
            let assembled = Self.assemble(result, dropping: droppedLabels,
                                          inferHeadingLevels: vlConfig.inferHeadingLevels)
            updated.status = .completed
            updated.ocrText = postProcess(assembled.text)
            updated.markdown = assembled.markdown
            updated.textLines = result.lines
            updated.layoutBlocks = result.blocks
            updated.blockSource = result.blockSource
            updated.derivesFromBlocks = result.derivesFromBlocks && !result.blocks.isEmpty
            updated.engine = settings.engine
            updated.rectifiedImage = result.rectified.map(ImageItem.page(from:))
            updated.processingProgress = 1.0
            items[i] = updated          // single assignment → one objectWillChange
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
            items[i] = updated
        }
    }

    /// Text plus whatever structure the engine managed to produce: per-line
    /// boxes from PP-OCRv6, a Markdown document from PaddleOCR-VL.
    /// What one file yielded.
    ///
    /// When `blocks` is non-empty the text and the Markdown are *derived* from
    /// it rather than stored, which is what lets 「保留页眉页脚」 be flipped after
    /// the fact instead of only before a run.
    struct Recognition: Sendable {
        var lines: [PPTextLine] = []
        var blocks: [PPLayoutBlock] = []
        /// Used when there are no blocks: Apple Vision, and PaddleOCR-VL's
        /// whole-page pass.
        var rawText: String = ""
        var rawMarkdown: String = ""
        /// Whether the block text is the VLM's markup-aware output or plain
        /// OCR lines. The assembler needs to know: wrapping a PP-OCR formula
        /// block in `$$` would claim a LaTeX transcription it never made.
        var blockSource: PPTextSource = .plainOCR
        /// The page after unwarping, when it ran: the boxes describe this
        /// image rather than the file on disk.
        var rectified: CGImage?
        /// False for a multi-page PDF, whose blocks only describe page one
        /// while the text covers the whole file. Re-deriving from those blocks
        /// would throw every page but the first away.
        var derivesFromBlocks: Bool = true
    }

    /// A snapshot of the state that affects recognition, read on the main
    /// actor before the work moves to a background task. Reading
    /// `self.ocrEngine` and friends from inside that task would just bounce
    /// back to the main actor on every access, defeating the detach.
    private struct RecognitionSettings: Sendable {
        var engine: OCREngine
        var visionLanguages: [String]
        var paddleConfig: PPOCRConfig
        var vlConfig: VLConfig
        /// Only used for a multi-page PDF, whose pages are assembled as they
        /// are read because only page one's blocks are kept afterwards.
        var droppedLabels: Set<PPLayoutLabel>
        var inferHeadingLevels: Bool
        var useDocUnwarping: Bool
    }

    private func currentRecognitionSettings() -> RecognitionSettings {
        RecognitionSettings(engine: ocrEngine, visionLanguages: recognitionLanguages,
                            paddleConfig: paddleConfig, vlConfig: vlConfig,
                            droppedLabels: droppedLabels,
                            inferHeadingLevels: vlConfig.inferHeadingLevels,
                            useDocUnwarping: useDocUnwarping)
    }

    // MARK: - Off-actor recognition
    //
    // Everything from here to `performVisionOCR` runs off the main actor.
    // `nonisolated` is required even though these are plain synchronous
    // functions that touch no actor state: being static members of a
    // `@MainActor` class would otherwise still bind them to it, and calling
    // one from `Task.detached` would just hop back onto the main actor —
    // silently undoing the detach and putting batch processing right back to
    // taking turns on a single thread.

    nonisolated private static func recognizeDocument(at url: URL, settings: RecognitionSettings,
                                                      paddleEngine: PPOCREngine?,
                                                      vlPipeline: VLDocumentPipeline?,
                                                      unwarper: PPDocUnwarper?,
                                                      isCancelled: @escaping () -> Bool,
                                                      progress: @escaping @Sendable (Double) -> Void) throws -> Recognition {
        if url.pathExtension.lowercased() == "pdf" {
            return try recognizePDF(at: url, settings: settings, paddleEngine: paddleEngine,
                                    vlPipeline: vlPipeline, unwarper: unwarper,
                                    isCancelled: isCancelled, progress: progress)
        }
        return try recognizeImage(at: url, settings: settings, paddleEngine: paddleEngine,
                                  vlPipeline: vlPipeline, unwarper: unwarper,
                                  isCancelled: isCancelled, progress: progress)
    }

    nonisolated private static func recognizeImage(at url: URL, settings: RecognitionSettings,
                                                   paddleEngine: PPOCREngine?,
                                                   vlPipeline: VLDocumentPipeline?,
                                                   unwarper: PPDocUnwarper?,
                                                   isCancelled: @escaping () -> Bool,
                                                   progress: @escaping @Sendable (Double) -> Void) throws -> Recognition {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.imageLoadFailed
        }
        progress(0.2)
        let result = try recognize(cgImage: cgImage, settings: settings, paddleEngine: paddleEngine,
                                   vlPipeline: vlPipeline, unwarper: unwarper,
                                   isCancelled: isCancelled, progress: progress)
        progress(1.0)
        return result
    }

    nonisolated private static func recognizePDF(at url: URL, settings: RecognitionSettings,
                                                 paddleEngine: PPOCREngine?,
                                                 vlPipeline: VLDocumentPipeline?,
                                                 unwarper: PPDocUnwarper?,
                                                 isCancelled: @escaping () -> Bool,
                                                 progress: @escaping @Sendable (Double) -> Void) throws -> Recognition {
        // Rasterise each page, then run the selected engine over it.
        guard let provider = CGDataProvider(url: url as CFURL),
              let pdfDoc = CGPDFDocument(provider) else {
            throw OCRError.imageLoadFailed
        }
        let pageCount = pdfDoc.numberOfPages
        var allText: [String] = []
        var allMarkdown: [String] = []
        // The preview shows page one, so that is the page the overlay describes.
        var firstPage = Recognition()
        let scale: CGFloat = 2.0

        for pageNum in 1...max(1, pageCount) {
            if isCancelled() { break }
            guard let page = pdfDoc.page(at: pageNum) else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            let size = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)
            guard let context = CGContext(
                data: nil,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.setFillColor(CGColor.white)
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            guard let cgImage = context.makeImage() else { continue }

            let result = try recognize(cgImage: cgImage, settings: settings, paddleEngine: paddleEngine,
                                       vlPipeline: vlPipeline, unwarper: unwarper,
                                       isCancelled: isCancelled, progress: nil)
            // Each page is turned into text as it is read: only page one's
            // blocks survive, so there is nothing left to assemble from later.
            let assembled = assemble(result, dropping: settings.droppedLabels,
                                     inferHeadingLevels: settings.inferHeadingLevels)
            if !assembled.text.isEmpty { allText.append(assembled.text) }
            if !assembled.markdown.isEmpty { allMarkdown.append(assembled.markdown) }
            if pageNum == 1 {
                // Boxes come back in rendered-page pixels; scale them down to the
                // page size the preview is drawn from.
                let shrink = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
                firstPage = result
                firstPage.blocks = result.blocks.map { block in
                    var block = block
                    block.rect = block.rect.applying(shrink)
                    return block
                }
                firstPage.lines = result.lines.map { line in
                    PPTextLine(quad: line.quad.map { CGPoint(x: $0.x / scale, y: $0.y / scale) },
                               text: line.text, confidence: line.confidence,
                               wasRotated: line.wasRotated)
                }
            }
            progress(Double(pageNum) / Double(pageCount))
        }

        var document = firstPage
        document.rawText = allText.joined(separator: "\n\n")
        document.rawMarkdown = allMarkdown.joined(separator: "\n\n---\n\n")
        // Page one's blocks describe page one only; the text above covers the
        // whole file, so it must not be rebuilt from them.
        document.derivesFromBlocks = pageCount <= 1
        return document
    }

    /// Text and Markdown for one recognition, honouring the page-furniture
    /// preference. Pure, and deliberately not on the main actor: the PDF path
    /// calls it per page from the worker thread, and the view model calls it
    /// again whenever the preference changes.
    nonisolated static func assemble(_ result: Recognition,
                                     dropping: Set<PPLayoutLabel>,
                                     inferHeadingLevels: Bool) -> (text: String, markdown: String) {
        guard !result.blocks.isEmpty else { return (result.rawText, result.rawMarkdown) }
        return (PPDocumentAssembler.plainText(from: result.blocks, dropping: dropping),
                PPDocumentAssembler.markdown(from: result.blocks, dropping: dropping,
                                             source: result.blockSource,
                                             inferHeadingLevels: inferHeadingLevels))
    }

    /// Sends one image to whichever engine is selected.
    nonisolated private static func recognize(cgImage source: CGImage, settings: RecognitionSettings,
                                              paddleEngine: PPOCREngine?,
                                              vlPipeline: VLDocumentPipeline?,
                                              unwarper: PPDocUnwarper?,
                                              isCancelled: @escaping () -> Bool,
                                              progress: (@Sendable (Double) -> Void)?) throws -> Recognition {
        // Flattening comes first, exactly as it does upstream: everything after
        // it — layout, detection, recognition — assumes text runs in straight
        // lines. A failure here is not fatal; the page is read as photographed.
        var cgImage = source
        var rectified: CGImage?
        if let unwarper, let buffer = PPImageBuffer(cgImage: source),
           let flattened = try? unwarper.rectify(buffer), let image = flattened.cgImage {
            cgImage = image
            rectified = image
        }

        switch settings.engine {
        case .visionFast, .visionAccurate:
            return Recognition(rawText: try performVisionOCR(on: cgImage, settings: settings),
                               rectified: rectified)
        case .paddleVL:
            guard let vlPipeline else {
                throw VLError.backendFailed("PaddleOCR-VL 模型未加载")
            }
            let document = try vlPipeline.parse(image: cgImage, config: settings.vlConfig,
                                                progress: { fraction, _ in progress?(fraction) },
                                                isCancelled: isCancelled)
            return Recognition(blocks: document.blocks,
                               rawText: document.plainText,
                               rawMarkdown: document.markdown,
                               blockSource: .visionLanguageModel,
                               rectified: rectified)
        case .paddleOCR:
            guard let paddleEngine else {
                throw PPOCRError.sessionFailed("PaddleOCR 模型未加载")
            }
            let page = try paddleEngine.recognize(
                image: cgImage, config: settings.paddleConfig,
                // Loading and decoding already covered the first fifth of the
                // bar; map the engine onto the rest.
                progress: progress.map { report in { report(0.2 + $0 * 0.8) } },
                isCancelled: isCancelled)
            return Recognition(lines: page.lines, blocks: page.blocks,
                               rawText: page.lines.plainText,
                               rectified: rectified)
        }
    }

    /// `VNImageRequestHandler.perform(_:)` is synchronous — it blocks the
    /// calling thread until every request's completion handler has already
    /// run — so plain local variables are enough here. The previous
    /// continuation-based version blocked the *main actor* for that same
    /// duration for no benefit, which was the main reason Vision batches never
    /// actually overlapped.
    nonisolated private static func performVisionOCR(on cgImage: CGImage, settings: RecognitionSettings) throws -> String {
        var text = ""
        var requestError: Error?
        let request = VNRecognizeTextRequest { req, err in
            if let err {
                requestError = err
                return
            }
            let observations = req.results as? [VNRecognizedTextObservation] ?? []
            text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }
        request.recognitionLevel = settings.engine == .visionFast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = settings.visionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let requestError { throw requestError }
        return text
    }

    // MARK: - PaddleOCR

    /// Reuses the loaded ONNX sessions unless the model files or backend changed.
    /// Builds the PaddleOCR-VL pipeline, reusing the loaded weights when the
    /// configuration has not changed. Loading costs seconds and a gigabyte or
    /// more, so this is deliberately sticky.
    private func loadVLPipeline(for config: VLConfig) async throws -> VLDocumentPipeline {
        if vlEngine == nil || !(vlEngine!.matchesModelConfiguration(config)) {
            vlEngine = try await Task.detached(priority: .userInitiated) {
                try VLEngine(config: config)
            }.value
        }

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

        return VLDocumentPipeline(layout: detector, vl: vlEngine!)
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

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed: return "无法加载图片文件"
        }
    }
}
