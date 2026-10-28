import SwiftUI

/// The app's settings, grouped by what the user is trying to do rather than by
/// which subsystem owns the code.
///
/// The engine choice and that engine's own options live together in one pane,
/// and only the selected engine's options are built. Panes therefore never show
/// controls the current engine ignores, which is what the previous layout's
/// "以下设置暂不生效" banners were apologising for.
struct SettingsView: View {
    @EnvironmentObject var vm: OCRViewModel
    @EnvironmentObject var updater: UpdaterController
    @Environment(\.openWindow) private var openWindow

    /// Remembered across openings: someone who tunes thresholds keeps coming
    /// back to the same section, and re-opening it every time is friction.
    @AppStorage("settings.paddleAdvancedExpanded") private var showPaddleAdvanced = false
    /// Applied by the main window, which watches the same key.
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @State private var showResetConfirm = false

    var body: some View {
        TabView {
            recognitionTab
                .tabItem { Label("Recognition", systemImage: "text.viewfinder") }
            textTab
                .tabItem { Label("Text & Export", systemImage: "text.alignleft") }
            behaviorTab
                .tabItem { Label("Behavior", systemImage: "gearshape.2") }
        }
        // A settings window sizes itself to its content, and a flexible frame
        // makes it pick something shorter than the panes actually need. Fixed,
        // and tall enough that the longest pane scrolls as little as possible.
        .frame(width: 560, height: 640)
    }

    // MARK: - Tab: Recognition

    private var recognitionTab: some View {
        settingsScroll {
            if vm.isProcessing {
                noticeBox("Recognition is running. Engine and model changes only affect files started afterwards.",
                          tint: .orange)
            }

            settingSection("Recognition Engine") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(OCREngine.allCases) { engine in
                        let ready = engine != .paddleVL || VLModelStore.isReady(for: vm.vlConfig)
                        radioRow(title: engine.label,
                                 subtitle: ready ? engine.hint : String(localized: "\(engine.hint) — model not downloaded yet"),
                                 selected: vm.ocrEngine == engine,
                                 enabled: ready) {
                            vm.ocrEngine = engine
                        }
                    }
                    if !VLModelStore.isReady(for: vm.vlConfig) {
                        Divider().padding(.vertical, 2)
                        modelManagerLink("Download PaddleOCR-VL Model")
                    }
                }
            }

            if vm.ocrEngine.usesVisionLanguages {
                visionSettings
            } else if vm.ocrEngine == .paddleOCR {
                paddleSettings
            } else if vm.ocrEngine == .auto {
                layeredSettings
            } else {
                vlSettings
            }
        }
    }

    // MARK: - Engine settings: Apple Vision

    @ViewBuilder
    private var visionSettings: some View {
        if vm.ocrEngine == .visionFast {
            noticeBox("Fast mode often garbles Chinese, Korean, decorative fonts and curved pages. If results look wrong, switch to Accurate before changing other settings.", tint: .orange)
        }

        settingSection("Recognition Languages (in priority order)") {
            VStack(alignment: .leading, spacing: 8) {
                // Vision weights the list by position, so the order is a
                // setting in its own right — it used to be whatever order the
                // boxes happened to be ticked in, with no way to change it.
                ForEach(Array(vm.recognitionLanguages.enumerated()), id: \.element) { index, code in
                    enabledLanguageRow(code: code, at: index)
                }
                if vm.recognitionLanguages.isEmpty {
                    Text("At least one language is required").font(.caption).foregroundStyle(.secondary)
                }
            }
            hint("Vision interprets an ambiguous glyph by the languages earlier in the list. On mixed-language pages, put the main language first — it makes a big difference. Korean placed after Chinese and English gets noticeably worse.")

            let available = Self.visionLanguages.filter { !vm.recognitionLanguages.contains($0.code) }
            if !available.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowingChips(items: available.map { ($0.code, $0.name) }) { code in
                    addLanguage(code)
                }
            }
        }
    }

    /// One enabled language: its rank, and the controls to move or drop it.
    private func enabledLanguageRow(code: String, at index: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(Self.languageName(code))
                .font(.callout)
            if index == 0 {
                Text("Primary")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
            Button { moveLanguage(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move up")
            Button { moveLanguage(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == vm.recognitionLanguages.count - 1)
                .help("Move down")
            Button { removeLanguage(code) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(vm.recognitionLanguages.count <= 1)
                .help(vm.recognitionLanguages.count <= 1 ? "At least one language must remain" : "Remove")
        }
    }

    private func addLanguage(_ code: String) {
        guard !vm.recognitionLanguages.contains(code) else { return }
        vm.recognitionLanguages.append(code)
    }

    private func removeLanguage(_ code: String) {
        guard vm.recognitionLanguages.count > 1 else { return }
        vm.recognitionLanguages.removeAll { $0 == code }
    }

    private func moveLanguage(at index: Int, by offset: Int) {
        let target = index + offset
        guard vm.recognitionLanguages.indices.contains(index),
              vm.recognitionLanguages.indices.contains(target) else { return }
        vm.recognitionLanguages.swapAt(index, target)
    }

    // MARK: - Inline model installation

    /// Downloads a catalogue entry without leaving this pane.
    ///
    /// The model manager still exists for the bulk of it, but sending someone
    /// to another window to fetch the one file the setting in front of them
    /// needs — and then back again to select it — is three steps too many.
    @ViewBuilder
    private func inlineDownloadRow(_ entry: PPModelCatalog.Entry) -> some View {
        let downloader = vm.modelDownloader
        let isDownloading = downloader.isDownloading(entry)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(entry.isInstalled ? Color.green : Color.secondary)
                Text(entry.name).font(.callout)
                Text("About \(Self.sizeText(entry.approximateBytes))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if isDownloading {
                    Button("Cancel") { downloader.cancel(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if entry.isInstalled {
                    Text("Installed").font(.caption).foregroundStyle(.green)
                } else {
                    Button("Download") { downloader.download(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if isDownloading {
                ProgressView(value: downloader.progress[entry.id] ?? 0)
                    .progressViewStyle(.linear)
            }
            if let error = downloader.errors[entry.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Which host the inline downloads use, and whether it answers.
    private var downloadSourceControl: some View {
        let downloader = vm.modelDownloader
        return HStack(spacing: 6) {
            Picker("", selection: Binding(get: { downloader.source },
                                          set: { downloader.source = $0 })) {
                ForEach(PPModelCatalog.Source.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Button("Test") { downloader.testSources() }
                .buttonStyle(.link)
                .controlSize(.small)
                .help("Send a request to both download sources to see which one works")

            switch downloader.reachability[downloader.source] {
            case .checking:
                ProgressView().controlSize(.small).scaleEffect(0.6)
            case let .reachable(milliseconds):
                Label("\(milliseconds) ms", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case let .unreachable(reason):
                Label(reason, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            case nil:
                EmptyView()
            }
        }
    }

    static func sizeText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// A friendly name for an installed single-language recogniser, falling
    /// back to the file's own name for one the user dropped in by hand.
    private static func recognizerName(_ recognizer: PPModelStore.InstalledRecognizer) -> String {
        let entry = PPModelCatalog.languageRecognizers.first {
            $0.recognizerFileName == recognizer.fileName
        }
        return entry.map { String(localized: "\($0.name) (\(recognizer.displayName))") } ?? recognizer.displayName
    }

    /// Catalogue languages whose recogniser is not on disk yet.
    private static var downloadableLanguages: [PPModelCatalog.Entry] {
        PPModelCatalog.languageRecognizers.filter { !$0.isInstalled }
    }

    private static func languageName(_ code: String) -> String {
        visionLanguages.first { $0.code == code }?.name ?? code
    }

    private static let visionLanguages: [(code: String, name: String)] = [
        ("zh-Hans", String(localized: "Simplified Chinese")),
        ("zh-Hant", String(localized: "Traditional Chinese")),
        ("en-US",   String(localized: "English")),
        ("ja-JP",   String(localized: "Japanese")),
        ("ko-KR",   String(localized: "Korean")),
        ("fr-FR",   String(localized: "French")),
        ("de-DE",   String(localized: "German")),
        ("es-ES",   String(localized: "Spanish")),
    ]

    // MARK: - Engine settings: 智能分层

    @AppStorage("settings.layeredPaddleExpanded") private var showLayeredPaddle = false
    @AppStorage("settings.layeredVLExpanded") private var showLayeredVL = false

    @ViewBuilder
    private var layeredSettings: some View {
        settingSection("Pipeline Components") {
            VStack(alignment: .leading, spacing: 8) {
                componentRow("PDF native text layer", detail: "Extracted directly, without OCR", ready: true)
                componentRow("PP-DocLayoutV3 layout analysis",
                             detail: "Decides which engine reads each region. Without it, whole pages use PP-OCRv6 only",
                             ready: VLModelStore.isLayoutModelInstalled)
                componentRow("PP-OCRv6 \(vm.paddleConfig.tier.label)", detail: "Body text, headings and other plain text",
                             ready: PPModelStore.isInstalled(vm.paddleConfig.tier))
                componentRow("PaddleOCR-VL \(vm.vlConfig.variant.label)",
                             detail: "Tables, formulas, charts, seals and low-confidence regions. Without it, these are only flagged for review",
                             ready: VLModelStore.isInstalled(vm.vlConfig.variant))
                let missing = [PPModelCatalog.layoutModel, PPModelCatalog.vlQuantized]
                    .filter { !$0.isInstalled }
                if !missing.isEmpty, !VLModelStore.isInstalled(vm.vlConfig.variant) || !VLModelStore.isLayoutModelInstalled {
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text("Not installed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        downloadSourceControl
                    }
                    ForEach(missing) { inlineDownloadRow($0) }
                }
            }
        }

        settingSection("Routing") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.layeredConfig.escalateLowConfidence,
                          title: "Reread low-confidence regions with PaddleOCR-VL",
                          subtitle: "Paragraphs PP-OCRv6 is unsure about are reread by the vision-language model. When off, they are only flagged for review")
                valueSlider("Reread threshold (average confidence)", value: $vm.layeredConfig.escalationConfidence,
                            range: 0.5...0.98, step: 0.01,
                            hint: "A region goes to PaddleOCR-VL when the average confidence of its PP-OCRv6 lines is below this value, or more than a quarter of its lines are below “Minimum confidence”. Higher is more accurate but slower")
                    .disabled(!vm.layeredConfig.escalateLowConfidence)
                Picker("When a PDF already has a text layer", selection: $vm.layeredConfig.pdfText) {
                    ForEach(PDFTextPolicy.allCases) { Text($0.label).tag($0) }
                }
                hint("Text in a native PDF is already exact, so using it directly is fastest and most accurate. Hidden OCR layers that other software added to scans are of unknown quality, so those pages are recognized again by default.")
            }
        }

        DisclosureGroup(isExpanded: $showLayeredPaddle) {
            VStack(alignment: .leading, spacing: 16) { paddleSettings }
                .padding(.top, 8)
        } label: {
            Text("PP-OCRv6 Parameters").font(.headline)
        }

        DisclosureGroup(isExpanded: $showLayeredVL) {
            VStack(alignment: .leading, spacing: 16) { vlSettings }
                .padding(.top, 8)
        } label: {
            Text("PaddleOCR-VL Parameters").font(.headline)
        }
    }

    private func componentRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, ready: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Engine settings: PaddleOCR

    @ViewBuilder
    private var paddleSettings: some View {
        settingSection("Model Tier") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PPModelTier.allCases) { tier in
                    let installed = PPModelStore.isInstalled(tier)
                    radioRow(title: tier.label,
                             subtitle: installed ? tier.hint : String(localized: "\(tier.hint) — not downloaded yet"),
                             selected: vm.paddleConfig.tier == tier,
                             enabled: installed) {
                        vm.selectTier(tier)
                    }
                }
                if !PPModelCatalog.mediumTier.isInstalled {
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text("Not installed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        downloadSourceControl
                    }
                    inlineDownloadRow(PPModelCatalog.mediumTier)
                }
                Divider().padding(.vertical, 2)
                modelManagerLink("Manage All Models…")
                hint("Switching tiers resets the detection thresholds to that tier's official defaults.")
            }
        }

        settingSection("Recognition Language") {
            VStack(alignment: .leading, spacing: 10) {
                radioRow(title: String(localized: "Built-in multilingual model"),
                         subtitle: String(localized: "A single PP-OCRv6 model covers 50 languages: Simplified and Traditional Chinese, English, Japanese, and 46 Latin-script languages. Not Korean, Arabic, Cyrillic, Thai, Greek or Devanagari"),
                         selected: vm.paddleConfig.recognizer == .builtin,
                         enabled: true) {
                    vm.selectRecognizer(.builtin)
                }
                ForEach(PPModelStore.installedCustomRecognizers()) { recognizer in
                    let choice = PPRecognizerChoice.custom(fileName: recognizer.fileName)
                    radioRow(title: Self.recognizerName(recognizer),
                             subtitle: String(localized: "An installed single-language recognizer; detection is still done by PP-OCRv6"),
                             selected: vm.paddleConfig.recognizer == choice,
                             enabled: true) {
                        vm.selectRecognizer(choice)
                    }
                }

                // The languages the built-in model cannot read are listed here,
                // and installed from here. Left invisible, the app answers a
                // Korean page with a page of wrong Chinese and nothing says
                // why; left to another window, installing one means losing
                // your place in this one.
                let missing = Self.downloadableLanguages
                if !missing.isEmpty {
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text("Languages not installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        downloadSourceControl
                    }
                    ForEach(missing) { entry in
                        inlineDownloadRow(entry)
                    }
                }
                hint("PP-OCRv6 has no weights for these languages; the built-in model would only produce garbage for them. Download them here, then select one above. Text detection is still done by PP-OCRv6.")
            }
        }

        settingSection("Reading Order & Layout") {
            VStack(alignment: .leading, spacing: 10) {
                let layoutReady = VLModelStore.isLayoutModelInstalled
                ForEach(PPTextOrder.allCases) { order in
                    let ready = !order.needsLayoutModel || layoutReady
                    radioRow(title: order.label,
                             subtitle: ready ? order.hint : String(localized: "\(order.hint) — not downloaded yet"),
                             selected: vm.paddleConfig.readingOrder == order,
                             enabled: ready) {
                        vm.paddleConfig.readingOrder = order
                    }
                }
                if !layoutReady {
                    Divider().padding(.vertical, 2)
                    inlineDownloadRow(PPModelCatalog.layoutModel)
                }
                hint("Text detection only gives each line's position, not its order. Layout analysis uses PP-DocLayoutV3 to find columns, headings, figures and other regions and decide the reading order, then places lines back into their regions — as PaddleOCR's official document parsing does. Results also gain heading levels and image positions, ready to export as Markdown.")
            }
        }

        settingSection("Compute Backend") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PPComputeUnit.allCases) { unit in
                    radioRow(title: unit.label, subtitle: unit.hint,
                             selected: vm.paddleConfig.computeUnit == unit, enabled: true) {
                        vm.paddleConfig.computeUnit = unit
                    }
                }
                Stepper(value: $vm.paddleConfig.threadCount, in: 0...16) {
                    Text(vm.paddleConfig.threadCount == 0
                         ? "Threads: Auto"
                         : "Threads: \(vm.paddleConfig.threadCount)")
                        .font(.callout)
                }
            }
        }

        settingSection("Image Preprocessing") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.useDocUnwarping,
                          title: "Page unwarping",
                          subtitle: "Flattens skewed, curled or folded pages before recognition. Scans don't need it. When on, the preview shows the flattened page")
                if vm.useDocUnwarping, !PPModelStore.isUnwarpingModelInstalled {
                    inlineDownloadRow(PPModelCatalog.unwarpingModel)
                }
                hint("Corresponds to PaddleOCR's use_doc_unwarping. Both engines use it.")
            }
        }

        settingSection("Orientation") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.paddleConfig.useDocOrientation,
                          title: "Page orientation correction",
                          subtitle: "Detects pages rotated 90°/180°/270° and straightens them. Recommended for scans")
                toggleRow(isOn: $vm.paddleConfig.useTextLineOrientation,
                          title: "Text line orientation correction",
                          subtitle: "Checks each line for upside-down text and flips it, with almost no speed cost")
                if vm.paddleConfig.useTextLineOrientation {
                    valueSlider("Flip threshold", value: $vm.paddleConfig.clsThresh,
                                range: 0.5...0.9, step: 0.05,
                                hint: "Lines below this confidence are not flipped. Model output clusters around 0.27 / 0.73")
                }
            }
        }

        settingSection("Text Detection & Recognition") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Detection resolution", selection: $vm.paddleConfig.detLimitSideLen) {
                    Text("736 (fastest)").tag(736)
                    Text("960 (default)").tag(960)
                    Text("1280").tag(1280)
                    Text("1600").tag(1600)
                    Text("2048 (best for small text)").tag(2048)
                }
                .pickerStyle(.menu)
                hint("The image's long side is scaled to this size before detection. Raise it for dense small text, at the cost of speed.")

                DisclosureGroup(isExpanded: $showPaddleAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        valueSlider("Binarization threshold", value: $vm.paddleConfig.detThresh,
                                    range: 0.1...0.9, step: 0.05,
                                    hint: "Probability threshold for text in the probability map. Lower it to catch fainter text")
                        valueSlider("Box threshold", value: $vm.paddleConfig.detBoxThresh,
                                    range: 0.1...0.95, step: 0.05,
                                    hint: "Candidate boxes with an average probability below this are discarded")
                        valueSlider("Box unclip ratio", value: $vm.paddleConfig.detUnclipRatio,
                                    range: 1.0...3.0, step: 0.1,
                                    hint: "Raise it to avoid clipping stroke edges; too high and neighboring text merges")
                        Stepper(value: $vm.paddleConfig.recBatchSize, in: 1...32) {
                            Text("Recognition batch size: \(vm.paddleConfig.recBatchSize)").font(.callout)
                        }
                        valueSlider("Minimum confidence", value: $vm.paddleConfig.dropScore,
                                    range: 0...0.95, step: 0.05,
                                    hint: "Lines recognized with lower confidence than this are left out of the results")
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced").font(.callout)
                }
            }
        }

        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Restore Defaults") { vm.resetPaddleTuning() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("Resets all orientation, detection and recognition parameters. The selected model and compute backend are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Engine settings: PaddleOCR-VL

    @ViewBuilder
    private var vlSettings: some View {
        settingSection("Model") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(VLModelVariant.allCases) { variant in
                    let installed = VLModelStore.isInstalled(variant)
                    radioRow(title: variant.label,
                             subtitle: installed ? variant.hint : String(localized: "\(variant.hint) — not downloaded yet"),
                             selected: vm.vlConfig.variant == variant,
                             enabled: installed) {
                        vm.vlConfig.variant = variant
                    }
                }
                Divider().padding(.vertical, 2)
                HStack {
                    modelManagerLink("Model Manager")
                    Spacer()
                    downloadSourceControl
                }
                ForEach(PPModelCatalog.vlEntries.filter { !$0.isInstalled }) { entry in
                    inlineDownloadRow(entry)
                }
            }
        }

        settingSection("Image Preprocessing") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.useDocUnwarping,
                          title: "Page unwarping",
                          subtitle: "Flattens skewed, curled or folded pages before recognition. Scans don't need it. When on, the preview shows the flattened page")
                if vm.useDocUnwarping, !PPModelStore.isUnwarpingModelInstalled {
                    inlineDownloadRow(PPModelCatalog.unwarpingModel)
                }
            }
        }

        settingSection("Layout Analysis") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.vlConfig.useLayoutDetection,
                          title: "Analyze layout first, then read block by block",
                          subtitle: "The official PaddleOCR pipeline: split the layout, decide the reading order, prompt each block appropriately, then assemble Markdown. When off, the whole page goes to the model at once — much faster, but content gets missed.")
                if !VLModelStore.isLayoutModelInstalled {
                    Label("The PP-DocLayoutV3 layout model isn't downloaded yet", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                valueSlider("Region padding ratio", value: $vm.vlConfig.cropUnclipRatio,
                            range: 1.0...1.3, step: 0.01,
                            hint: "How far to expand each layout region when cropping. Cropping tight to the text cuts off stroke edges and the model misses characters. Corresponds to the official unclip_ratio")

                if !vm.vlConfig.useLayoutDetection {
                    Divider().padding(.vertical, 2)
                    Picker("Whole-page prompt", selection: $vm.vlConfig.wholeImageTask) {
                        ForEach(VLTask.allCases) { task in
                            Text("\(task.label) (\(task.prompt))").tag(task)
                        }
                    }
                    hint(verbatim: vm.vlConfig.wholeImageTask.hint)
                }
            }
        }

        settingSection("Recognition Modules") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.vlConfig.useChartRecognition,
                          title: "Chart recognition",
                          subtitle: "Reads bar and line charts into data tables. Off by default upstream — a chart only draws shapes, so the numbers are the model's estimates")
                toggleRow(isOn: $vm.vlConfig.useSealRecognition,
                          title: "Seal recognition",
                          subtitle: "Reads the curved text on seals")
                toggleRow(isOn: $vm.vlConfig.useImageTextRecognition,
                          title: "Text in images",
                          subtitle: "Also reads text inside image regions. When off, images are kept as illustrations only")
                toggleRow(isOn: $vm.vlConfig.inferHeadingLevels,
                          title: "Heading level detection",
                          subtitle: "Infers heading levels from font size and outputs ##, ###, ####. When off, all subheadings are one level")
                hint("Regions of a disabled module still appear in the preview; they just aren't sent for recognition.")
            }
        }

        settingSection("Sampling") {
            VStack(alignment: .leading, spacing: 12) {
                valueSlider("Repetition penalty", value: $vm.vlConfig.repetitionPenalty,
                            range: 1.0...1.5, step: 0.05,
                            hint: "Above 1, tokens already output are less likely to appear again. If whole passages repeat, try 1.05–1.15")
                valueSlider("Randomness (temperature)", value: $vm.vlConfig.temperature,
                            range: 0...1.0, step: 0.05,
                            hint: "0 always picks the most likely token, which is also the official default. Higher values add randomness, which rarely helps transcription.")
                valueSlider("Candidate range (top-p)", value: $vm.vlConfig.topP,
                            range: 0.1...1.0, step: 0.05,
                            hint: "Only applies when temperature is above 0: samples from the candidates whose cumulative probability reaches this value")
                hint("These match PaddleOCR's three official sampling parameters, with the same defaults (1.00 / 0.00 / 1.0).")
            }
        }

        settingSection("Inference") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.vlConfig.useGPU,
                          title: "Use GPU (Metal)",
                          subtitle: "Runs all layers on the GPU, several times faster than CPU alone (recommended)")
                Stepper(value: $vm.vlConfig.contextTokens, in: 2048...32768, step: 2048) {
                    Text("Context length: \(vm.vlConfig.contextTokens)").font(.callout)
                }
                Stepper(value: $vm.vlConfig.maxOutputTokens, in: 128...4096, step: 128) {
                    Text("Max output per block: \(vm.vlConfig.maxOutputTokens) tokens").font(.callout)
                }
                hint("The context must fit one block's visual tokens plus its output. The per-block output limit keeps one block from stalling the whole page.")
                Divider().padding(.vertical, 2)
                Picker("Regions decoded in parallel", selection: $vm.vlConfig.parallelSequences) {
                    Text("Auto (\(VLConfig().resolvedParallelism) on this Mac)").tag(0)
                    ForEach(VLConfig.parallelismChoices, id: \.self) { Text("\($0) lanes").tag($0) }
                }
                hint("Regions from the same page, neighboring pages and neighboring files are decoded together on the GPU. Each region's crop, prompt and decoding are unchanged, so results match one-at-a-time reading, only faster. Each extra lane uses about 45 MB more memory.")
            }
        }
    }

    // MARK: - Tab: Text & export

    private var textTab: some View {
        settingsScroll {
            settingSection("Line Breaks") {
                VStack(alignment: .leading, spacing: 10) {
                    // Never disabled: it used to switch itself off once both were
                    // on, which left the pair locked with no way back.
                    toggleRow(isOn: $vm.mergeLineBreaks,
                              title: "Merge into one line (no line breaks)",
                              subtitle: "Replaces every line break with a space, producing continuous paragraphs")
                    toggleRow(isOn: $vm.removeEmptyLines,
                              title: "Remove extra blank lines",
                              subtitle: "Collapses consecutive blank lines into one")
                        .disabled(vm.mergeLineBreaks)
                    if vm.mergeLineBreaks {
                        hint("After merging into one line there are no line breaks left, so “Remove extra blank lines” has no effect.")
                    }
                }
            }

            settingSection("Whitespace") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $vm.trimWhitespace,
                              title: "Trim spaces at line ends",
                              subtitle: "Removes extra whitespace at both ends of each line")
                    toggleRow(isOn: $vm.removeHyphenBreaks,
                              title: "Join hyphenated line breaks",
                              subtitle: "Good for English scans: rejoins words split across lines")
                }
            }

            if vm.mergeLineBreaks || vm.removeEmptyLines || vm.trimWhitespace || vm.removeHyphenBreaks {
                noticeBox("Text post-processing only affects new results; existing ones are not changed.", tint: .accentColor)
            }

            settingSection("Auxiliary Content") {
                VStack(alignment: .leading, spacing: 8) {
                    hint("Headers, footers, page numbers and the like are detected by the layout model and filtered out by default. Turn an item on to keep it in the results. Matches PaddleOCR's official auxiliary content options.")
                    ForEach(PPLayoutLabel.auxiliary, id: \.rawValue) { label in
                        Toggle(isOn: Binding(
                            get: { vm.keptAuxiliary.contains(label) },
                            set: { vm.setAuxiliary(label, kept: $0) })) {
                            HStack(spacing: 6) {
                                Text(label.label).font(.callout)
                                Text(label.rawName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Divider().padding(.vertical, 2)
                    hint("These regions are always recognized and always drawn in the preview (filtered ones with dashed boxes); this only decides whether they go into the text and Markdown. Changes apply immediately without recognizing again — except for multi-page PDFs, whose text is assembled page by page during recognition.")
                }
            }

            settingSection("Result Rendering") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $vm.renderFigures,
                              title: "Show images and charts",
                              subtitle: "Crops images and charts from the original at their detected positions and shows them in the Markdown result")
                    toggleRow(isOn: $vm.renderTables,
                              title: "Render tables as grids",
                              subtitle: "When off, tables are shown as the model output them")
                    hint("Only affects how the Markdown tab displays; the Source tab always shows the model's raw output. Other engines produce plain text and are not affected.")
                }
            }

            settingSection("Export") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Export format", selection: $vm.exportFormat) {
                        ForEach(OCRViewModel.ExportFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    hint(verbatim: exportFormatHint)

                    Picker("Export as", selection: $vm.exportLayout) {
                        ForEach(OCRViewModel.ExportLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                    hint(vm.exportLayout == .combined
                         ? "All selected files are written into one document."
                         : "Choose a folder; each image is written to its own “original name_OCR” document.")

                    if vm.exportFormat == .markdown {
                        Divider()
                        Toggle("Save images when exporting Markdown", isOn: $vm.exportFigures)
                        hint("Images go into an .assets folder named after the .md file and are referenced by relative path. When off, image positions keep only an empty placeholder.")
                    }

                    if vm.exportLayout == .combined, vm.exportFormat != .json {
                        Divider()
                        Picker("File separator", selection: $vm.exportSeparator) {
                            ForEach(OCRViewModel.ExportSeparator.allCases) { separator in
                                Text(separator.label).tag(separator)
                            }
                        }
                        .pickerStyle(.menu)
                        hint("How files are separated when several are exported into one text.")
                    }

                    if vm.exportFormat != .json {
                        Toggle("Include file names when exporting", isOn: $vm.exportIncludeFilename)
                        hint(vm.exportFormat == .markdown
                             ? "When on, each file's content starts with a level-1 heading."
                             : "When on, each file's content starts with a “=== file name ===” line.")
                    }
                }
            }
        }
    }

    // MARK: - Tab: Behavior

    private var behaviorTab: some View {
        settingsScroll {
            settingSection("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            settingSection("Automation") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $vm.autoStartOnAdd,
                              title: "Start recognition automatically after adding files",
                              subtitle: "Start processing as soon as files are dropped in or chosen")
                    toggleRow(isOn: $vm.skipCompleted,
                              title: "Skip completed files",
                              subtitle: "When you click Start Recognition again, files already recognized are not processed again")
                }
            }

            settingSection("Watched Folder") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $vm.watchEnabled,
                              title: "Automatically recognize new files added to a folder",
                              subtitle: "Includes subfolders. Files are read once they finish writing; originals are never moved or deleted")
                    folderRow("Watch", url: vm.watchFolder) { vm.chooseWatchFolder(output: false) }
                    folderRow("Output", url: vm.watchOutputFolder) { vm.chooseWatchFolder(output: true) }
                    if vm.watchEnabled, vm.watchFolder == nil {
                        Label("Choose a folder to watch first", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    hint("Once a file is recognized, it is written to the output folder in the format chosen under Text & Export, keeping the subfolder structure. Source files whose output already exists count as done and aren't recognized again. Without an output folder, results stay in the list only.")
                }
            }

            settingSection("Recognition Cache") {
                VStack(alignment: .leading, spacing: 10) {
                    hint("If the same file (judged by content, regardless of name or location) was recognized with the same settings, the earlier result is reused. “Recognize Again” always reads afresh. The list and results are kept after quitting and are there next time.")
                    Button("Clear Recognition Cache") { vm.store.clearCache() }
                        .controlSize(.small)
                }
            }

            settingSection("Batch Concurrency") {
                VStack(alignment: .leading, spacing: 10) {
                    // The GPU engines batch regions across files themselves, so
                    // `processConcurrently` caps them at two files in flight.
                    let capped = vm.ocrEngine.prefersFewFilesInFlight
                    Stepper(value: $vm.maxConcurrentTasks, in: 1...8) {
                        Text(capped
                             ? "Process \(min(2, vm.maxConcurrentTasks)) files at a time"
                             : "Process \(vm.maxConcurrentTasks) files at a time")
                            .font(.callout)
                    }
                    hint(verbatim: concurrencyHint)
                }
            }

            settingSection("Software Update") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $updater.automaticallyChecksForUpdates,
                              title: "Check for updates automatically",
                              subtitle: "Checks GitHub Releases for new versions in the background and asks before downloading")
                    HStack(spacing: 10) {
                        Button("Check Now…") { updater.checkForUpdates() }
                            .buttonStyle(.bordered)
                            .disabled(!updater.canCheckForUpdates)
                        Text("Current version \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            settingSection("Reset") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Restore All Defaults…") { showResetConfirm = true }
                        .buttonStyle(.bordered)
                    hint("Settings are saved automatically and kept for the next launch. This restores all three tabs to their initial state.")
                }
            }
            .confirmationDialog("Restore all default settings?",
                                isPresented: $showResetConfirm,
                                titleVisibility: .visible) {
                Button("Reset All Settings", role: .destructive) { vm.resetAllSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(String(localized: "The recognition engine, model choices, all parameters, and text and export options return to their initial values. Downloaded models and files in the list are not affected."))
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var exportFormatHint: String {
        switch vm.exportFormat {
        case .markdown:
            return String(localized: "Keeps heading levels, image positions and tables. Only results with layout analysis have this structure (PaddleOCR-VL, or PP-OCRv6 with layout analysis on); others fall back to plain text.")
        case .plainText:
            return String(localized: "Writes only the recognized text, with no structure.")
        case .json:
            return String(localized: "Writes, page by page, each line's text, four-point coordinates and confidence, plus each layout region's type, reading order, position, which engine read it and why it needs review — for further processing by other programs.")
        case .excel:
            return String(localized: "Writes tables with recognized structure to an Excel workbook, one sheet per table, keeping merged cells merged and writing plain numbers as numbers. Table structure comes from PaddleOCR-VL; tables PP-OCRv6 read as text are not exported.")
        case .searchablePDF:
            return String(localized: "Keeps each page as it looks (PDF pages stay vector, not re-rasterized) and lays the recognized text over it as an invisible layer, so it can be searched and copied in Preview, Spotlight and elsewhere. Pages that already have a text layer are left alone.")
        }
    }

    private var concurrencyHint: String {
        switch vm.ocrEngine {
        case .paddleVL, .auto:
            return String(localized: "GPU models batch regions from several files and pages and decode them together. Two files at a time is enough to keep the GPU busy; more only uses more memory.")
        case .paddleOCR:
            return String(localized: "Image decoding runs truly in parallel. PaddleOCR inference still runs one image at a time (so multiple model copies don't fight over the CPU), but the next image's decoding no longer waits.")
        case .visionFast, .visionAccurate:
            return String(localized: "Several images are decoded and recognized by Apple Vision at once, making full use of a multi-core CPU.")
        }
    }

    // MARK: - Building blocks

    private func folderRow(_ title: LocalizedStringKey, url: URL?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(width: 44, alignment: .leading)
            Text(url?.path(percentEncoded: false) ?? String(localized: "Not chosen"))
                .font(.caption)
                .foregroundStyle(url == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(url?.path(percentEncoded: false) ?? "")
            Button("Choose…", action: choose).controlSize(.small)
        }
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func settingSection<Content: View>(_ title: LocalizedStringKey,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        hint(Text(text))
    }

    /// For text that is already localised, such as an enum's description.
    private func hint(verbatim text: String) -> some View {
        hint(Text(verbatim: text))
    }

    private func hint(_ text: Text) -> some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func noticeBox(_ text: LocalizedStringKey, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func modelManagerLink(_ title: LocalizedStringKey) -> some View {
        Button {
            openWindow(id: ModelManagerView.windowID)
        } label: {
            Label(title, systemImage: "square.and.arrow.down")
                .font(.callout)
        }
        .buttonStyle(.link)
    }

    /// The whole strip is the click target, not just the glyphs — the gaps
    /// between the dot and the text used to swallow clicks.
    @ViewBuilder
    private func radioRow(title: String, subtitle: String, selected: Bool,
                          enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 15))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func toggleRow(isOn: Binding<Bool>, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func valueSlider(_ title: LocalizedStringKey, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double,
                             hint text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            hint(text)
        }
    }

}

/// A row of "+ name" buttons that wraps onto as many lines as it needs.
private struct FlowingChips: View {
    let items: [(code: String, name: String)]
    let action: (String) -> Void

    var body: some View {
        // `Grid` would align the columns; languages have names of very
        // different widths, so a wrapping flow reads better.
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.code) { item in
                Button {
                    action(item.code)
                } label: {
                    Label(item.name, systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

/// Lays its subviews out left to right, wrapping at the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
