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
    @Environment(\.openWindow) private var openWindow

    /// Remembered across openings: someone who tunes thresholds keeps coming
    /// back to the same section, and re-opening it every time is friction.
    @AppStorage("settings.paddleAdvancedExpanded") private var showPaddleAdvanced = false
    @State private var showResetConfirm = false

    var body: some View {
        TabView {
            recognitionTab
                .tabItem { Label("识别", systemImage: "text.viewfinder") }
            textTab
                .tabItem { Label("文本与导出", systemImage: "text.alignleft") }
            behaviorTab
                .tabItem { Label("行为", systemImage: "gearshape.2") }
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
                noticeBox("正在识别中，更改引擎或模型设置只会影响之后开始的文件。",
                          tint: .orange)
            }

            settingSection("识别引擎") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(OCREngine.allCases) { engine in
                        let ready = engine != .paddleVL || VLModelStore.isReady(for: vm.vlConfig)
                        radioRow(title: engine.label,
                                 subtitle: ready ? engine.hint : "\(engine.hint) —— 模型尚未下载",
                                 selected: vm.ocrEngine == engine,
                                 enabled: ready) {
                            vm.ocrEngine = engine
                        }
                    }
                    if !VLModelStore.isReady(for: vm.vlConfig) {
                        Divider().padding(.vertical, 2)
                        modelManagerLink("下载 PaddleOCR-VL 模型")
                    }
                }
            }

            if vm.ocrEngine.usesVisionLanguages {
                visionSettings
            } else if vm.ocrEngine == .paddleOCR {
                paddleSettings
            } else {
                vlSettings
            }
        }
    }

    // MARK: - Engine settings: Apple Vision

    @ViewBuilder
    private var visionSettings: some View {
        if vm.ocrEngine == .visionFast {
            noticeBox("快速模式在中文、韩文、艺术字体和弯曲页面上容易出现乱码，"
                      + "结果不对时先换成「精准模式」再调其它设置。", tint: .orange)
        }

        settingSection("识别语言（按优先级）") {
            VStack(alignment: .leading, spacing: 8) {
                // Vision weights the list by position, so the order is a
                // setting in its own right — it used to be whatever order the
                // boxes happened to be ticked in, with no way to change it.
                ForEach(Array(vm.recognitionLanguages.enumerated()), id: \.element) { index, code in
                    enabledLanguageRow(code: code, at: index)
                }
                if vm.recognitionLanguages.isEmpty {
                    Text("至少需要一种语言").font(.caption).foregroundStyle(.secondary)
                }
            }
            hint("Vision 会优先按靠前的语言来判读同一个字形。混排页面把主要语言排在第一位，"
                 + "识别质量差别很大——韩文排在中文、英文之后就会明显变差。")

            let available = Self.visionLanguages.filter { !vm.recognitionLanguages.contains($0.code) }
            if !available.isEmpty {
                Divider().padding(.vertical, 4)
                Text("可添加")
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
                Text("首选")
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
                .help("上移一位")
            Button { moveLanguage(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == vm.recognitionLanguages.count - 1)
                .help("下移一位")
            Button { removeLanguage(code) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(vm.recognitionLanguages.count <= 1)
                .help(vm.recognitionLanguages.count <= 1 ? "至少要保留一种语言" : "移除")
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

    /// A friendly name for an installed single-language recogniser, falling
    /// back to the file's own name for one the user dropped in by hand.
    private static func recognizerName(_ recognizer: PPModelStore.InstalledRecognizer) -> String {
        let entry = PPModelCatalog.languageRecognizers.first {
            $0.recognizerFileName == recognizer.fileName
        }
        return entry.map { "\($0.name)（\(recognizer.displayName)）" } ?? recognizer.displayName
    }

    /// Catalogue languages whose recogniser is not on disk yet.
    private static var downloadableLanguages: [PPModelCatalog.Entry] {
        PPModelCatalog.languageRecognizers.filter { !$0.isInstalled }
    }

    private static func languageName(_ code: String) -> String {
        visionLanguages.first { $0.code == code }?.name ?? code
    }

    private static let visionLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文"),
        ("en-US",   "英文"),
        ("ja-JP",   "日文"),
        ("ko-KR",   "韩文"),
        ("fr-FR",   "法文"),
        ("de-DE",   "德文"),
        ("es-ES",   "西班牙文"),
    ]

    // MARK: - Engine settings: PaddleOCR

    @ViewBuilder
    private var paddleSettings: some View {
        settingSection("模型档位") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PPModelTier.allCases) { tier in
                    let installed = PPModelStore.isInstalled(tier)
                    radioRow(title: tier.label,
                             subtitle: installed ? tier.hint : "\(tier.hint) —— 尚未下载",
                             selected: vm.paddleConfig.tier == tier,
                             enabled: installed) {
                        vm.selectTier(tier)
                    }
                }
                Divider().padding(.vertical, 2)
                modelManagerLink("模型管理")
                hint("切换档位会把检测阈值恢复为该档位的官方默认值。"
                     + "medium 档位与其他语种识别器可在模型管理中下载。")
            }
        }

        settingSection("识别语言") {
            VStack(alignment: .leading, spacing: 10) {
                radioRow(title: "内置多语言模型",
                         subtitle: "PP-OCRv6 单模型覆盖 50 种语言：简繁中文、英文、日文，以及 46 种拉丁语系语言。"
                                 + "不含韩文、阿拉伯文、西里尔字母、泰文、希腊文、天城文",
                         selected: vm.paddleConfig.recognizer == .builtin,
                         enabled: true) {
                    vm.selectRecognizer(.builtin)
                }
                ForEach(PPModelStore.installedCustomRecognizers()) { recognizer in
                    let choice = PPRecognizerChoice.custom(fileName: recognizer.fileName)
                    radioRow(title: Self.recognizerName(recognizer),
                             subtitle: "已安装的单语种识别器，检测仍由 PP-OCRv6 完成",
                             selected: vm.paddleConfig.recognizer == choice,
                             enabled: true) {
                        vm.selectRecognizer(choice)
                    }
                }

                // The languages the built-in model cannot read are listed here
                // rather than only inside the model manager. Left invisible,
                // the app answers a Korean page with a page of wrong Chinese
                // and nothing says why.
                let missing = Self.downloadableLanguages
                if !missing.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("尚未安装的语种")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(missing) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                            Text(entry.name).font(.callout)
                            Text("约 16 MB")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Button("下载…") { openWindow(id: ModelManagerView.windowID) }
                                .buttonStyle(.link)
                                .controlSize(.small)
                        }
                    }
                }
                hint("PP-OCRv6 没有这些语种的权重，用内置模型识别它们只会得到一堆错字。"
                     + "装上对应的 PP-OCRv5 识别器后在这里选中即可；文本检测仍由 PP-OCRv6 完成。")
            }
        }

        settingSection("阅读顺序") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PPTextOrder.allCases) { order in
                    radioRow(title: order.label, subtitle: order.hint,
                             selected: vm.paddleConfig.readingOrder == order, enabled: true) {
                        vm.paddleConfig.readingOrder = order
                    }
                }
                hint("检测模型只给出文本框的位置，不给出先后。「按栏排序」先找出栏与栏之间的空白，"
                     + "再逐栏自上而下拼接，报刊、试卷这类多栏版面才不会左右串行。")
            }
        }

        settingSection("计算后端") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PPComputeUnit.allCases) { unit in
                    radioRow(title: unit.label, subtitle: unit.hint,
                             selected: vm.paddleConfig.computeUnit == unit, enabled: true) {
                        vm.paddleConfig.computeUnit = unit
                    }
                }
                Stepper(value: $vm.paddleConfig.threadCount, in: 0...16) {
                    Text(vm.paddleConfig.threadCount == 0
                         ? "线程数：自动"
                         : "线程数：\(vm.paddleConfig.threadCount)")
                        .font(.callout)
                }
            }
        }

        settingSection("方向校正") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.paddleConfig.useDocOrientation,
                          title: "整页方向校正",
                          subtitle: "识别整页旋转 90°/180°/270° 并自动摆正；扫描件建议开启")
                toggleRow(isOn: $vm.paddleConfig.useTextLineOrientation,
                          title: "文本行方向校正",
                          subtitle: "逐行判断是否倒置并翻转，几乎不影响速度")
                if vm.paddleConfig.useTextLineOrientation {
                    valueSlider("翻转判定阈值", value: $vm.paddleConfig.clsThresh,
                                range: 0.5...0.9, step: 0.05,
                                hint: "低于该置信度则不翻转；模型输出集中在 0.27 / 0.73 附近")
                }
            }
        }

        settingSection("文本检测与识别") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("检测分辨率", selection: $vm.paddleConfig.detLimitSideLen) {
                    Text("736（最快）").tag(736)
                    Text("960（默认）").tag(960)
                    Text("1280").tag(1280)
                    Text("1600").tag(1600)
                    Text("2048（小字最佳）").tag(2048)
                }
                .pickerStyle(.menu)
                hint("图片长边会缩放到该尺寸再送入检测模型。密集小字可调高，速度随之下降。")

                DisclosureGroup(isExpanded: $showPaddleAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        valueSlider("二值化阈值", value: $vm.paddleConfig.detThresh,
                                    range: 0.1...0.9, step: 0.05,
                                    hint: "概率图判定为文字的阈值，调低可召回更淡的文字")
                        valueSlider("文本框阈值", value: $vm.paddleConfig.detBoxThresh,
                                    range: 0.1...0.95, step: 0.05,
                                    hint: "候选框平均概率低于此值将被丢弃")
                        valueSlider("文本框扩张系数", value: $vm.paddleConfig.detUnclipRatio,
                                    range: 1.0...3.0, step: 0.1,
                                    hint: "调大可避免笔画边缘被裁掉，过大则相邻文字会粘连")
                        Stepper(value: $vm.paddleConfig.recBatchSize, in: 1...32) {
                            Text("识别批大小：\(vm.paddleConfig.recBatchSize)").font(.callout)
                        }
                        valueSlider("最低置信度", value: $vm.paddleConfig.dropScore,
                                    range: 0...0.95, step: 0.05,
                                    hint: "识别置信度低于此值的文本行不会出现在结果中")
                    }
                    .padding(.top, 8)
                } label: {
                    Text("高级参数").font(.callout)
                }
            }
        }

        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("恢复默认值") { vm.resetPaddleTuning() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("恢复方向校正、检测与识别的全部参数，保留所选模型与计算后端。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Engine settings: PaddleOCR-VL

    @ViewBuilder
    private var vlSettings: some View {
        settingSection("模型") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(VLModelVariant.allCases) { variant in
                    let installed = VLModelStore.isInstalled(variant)
                    radioRow(title: variant.label,
                             subtitle: installed ? variant.hint : "\(variant.hint) —— 尚未下载",
                             selected: vm.vlConfig.variant == variant,
                             enabled: installed) {
                        vm.vlConfig.variant = variant
                    }
                }
                Divider().padding(.vertical, 2)
                modelManagerLink("模型管理")
            }
        }

        settingSection("版面分析") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.vlConfig.useLayoutDetection,
                          title: "先做版面分析，再逐块识别",
                          subtitle: "PaddleOCR 官方管线：切分版面、判定阅读顺序，逐块选用合适的提示词，"
                                  + "最后拼成 Markdown。关闭后整页一次性交给模型，快得多但会漏内容。")
                if !VLModelStore.isLayoutModelInstalled {
                    Label("尚未下载 PP-DocLayoutV3 版面模型", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                toggleRow(isOn: $vm.vlConfig.dropPageFurniture,
                          title: "丢弃页眉、页脚与页码",
                          subtitle: "这些内容每页重复，通常只是噪音。"
                                  + "只丢弃真正位于页边的短块；若发现标题一类的内容仍被吞掉，可关掉这一项")

                if !vm.vlConfig.useLayoutDetection {
                    Divider().padding(.vertical, 2)
                    Picker("整页提示词", selection: $vm.vlConfig.wholeImageTask) {
                        ForEach(VLTask.allCases) { task in
                            Text("\(task.label)（\(task.prompt)）").tag(task)
                        }
                    }
                    hint(vm.vlConfig.wholeImageTask.hint)
                }
            }
        }

        settingSection("推理") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(isOn: $vm.vlConfig.useGPU,
                          title: "使用 GPU（Metal）",
                          subtitle: "把全部层放到 GPU 上，比纯 CPU 快数倍（推荐）")
                Stepper(value: $vm.vlConfig.contextTokens, in: 2048...32768, step: 2048) {
                    Text("上下文长度：\(vm.vlConfig.contextTokens)").font(.callout)
                }
                Stepper(value: $vm.vlConfig.maxOutputTokens, in: 128...4096, step: 128) {
                    Text("单块最大输出：\(vm.vlConfig.maxOutputTokens) token").font(.callout)
                }
                hint("上下文要装得下一块图像的视觉 token 加上它的输出；单块输出上限防止某一块卡住整页。")
            }
        }
    }

    // MARK: - Tab: Text & export

    private var textTab: some View {
        settingsScroll {
            settingSection("换行处理") {
                VStack(alignment: .leading, spacing: 10) {
                    // Never disabled: it used to switch itself off once both were
                    // on, which left the pair locked with no way back.
                    toggleRow(isOn: $vm.mergeLineBreaks,
                              title: "合并为单行（不换行）",
                              subtitle: "将所有换行替换为空格，输出连续段落")
                    toggleRow(isOn: $vm.removeEmptyLines,
                              title: "去除多余空行",
                              subtitle: "将连续多个空行压缩为单个空行")
                        .disabled(vm.mergeLineBreaks)
                    if vm.mergeLineBreaks {
                        hint("合并为单行后结果里不再有换行，「去除多余空行」无从生效。")
                    }
                }
            }

            settingSection("空白字符") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $vm.trimWhitespace,
                              title: "去除行首尾空格",
                              subtitle: "清除每行两端多余的空白字符")
                    toggleRow(isOn: $vm.removeHyphenBreaks,
                              title: "合并连字符换行",
                              subtitle: "适合英文扫描件，自动拼合被断行分割的单词")
                }
            }

            if vm.mergeLineBreaks || vm.removeEmptyLines || vm.trimWhitespace || vm.removeHyphenBreaks {
                noticeBox("文本后处理仅影响新识别的结果，不会修改已有内容。", tint: .accentColor)
            }

            settingSection("结果渲染") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $vm.renderFigures,
                              title: "显示图片与图表",
                              subtitle: "把版面里的图片、图表按识别到的位置从原图裁出来，显示在 Markdown 结果中")
                    toggleRow(isOn: $vm.renderTables,
                              title: "表格渲染为网格",
                              subtitle: "关闭后按模型输出的原始形式显示表格")
                    hint("仅影响「Markdown」标签页的显示方式；「源码」标签页始终是模型输出的原文。"
                         + "其它引擎只有纯文本，不受这里影响。")
                }
            }

            settingSection("导出") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("导出 Markdown 时一并保存图片", isOn: $vm.exportFigures)
                    hint("图片写入与 .md 同名的 .assets 文件夹，文档中以相对路径引用；"
                         + "关闭后图片位置只保留空的占位符。")

                    Picker("文件分隔符", selection: $vm.exportSeparator) {
                        ForEach(OCRViewModel.ExportSeparator.allCases) { separator in
                            Text(separator.rawValue).tag(separator)
                        }
                    }
                    .pickerStyle(.menu)
                    hint("多个文件导出为同一文本时，各文件内容之间的分隔方式。")

                    Toggle("导出时包含文件名", isOn: $vm.exportIncludeFilename)
                    hint("开启后每段内容前会加上「=== 文件名 ===」标题行。")
                }
            }
        }
    }

    // MARK: - Tab: Behavior

    private var behaviorTab: some View {
        settingsScroll {
            settingSection("自动化") {
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow(isOn: $vm.autoStartOnAdd,
                              title: "添加文件后自动开始识别",
                              subtitle: "拖入或选择文件后立即开始批量处理")
                    toggleRow(isOn: $vm.skipCompleted,
                              title: "跳过已完成的文件",
                              subtitle: "重新点击「开始识别」时，不重复处理已识别的文件")
                }
            }

            settingSection("批量并发") {
                VStack(alignment: .leading, spacing: 10) {
                    // PaddleOCR-VL keeps a single llama context with one KV cache,
                    // so `processConcurrently` pins it to one image at a time no
                    // matter what this says.
                    let lockedToSingle = vm.ocrEngine == .paddleVL
                    Stepper(value: $vm.maxConcurrentTasks, in: 1...8) {
                        Text(lockedToSingle
                             ? "同时处理 1 个文件"
                             : "同时处理 \(vm.maxConcurrentTasks) 个文件")
                            .font(.callout)
                    }
                    .disabled(lockedToSingle)
                    hint(concurrencyHint)
                }
            }

            settingSection("重置") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("恢复全部默认设置…") { showResetConfirm = true }
                        .buttonStyle(.bordered)
                    hint("设置会自动保存并在下次启动时沿用；这里可以把全部三个标签页恢复到初始状态。")
                }
            }
            .confirmationDialog("恢复全部默认设置？",
                                isPresented: $showResetConfirm,
                                titleVisibility: .visible) {
                Button("恢复默认设置", role: .destructive) { vm.resetAllSettings() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("识别引擎、模型选择、全部参数、文本与导出选项都会回到初始值。"
                     + "已下载的模型和列表中的文件不受影响。")
            }
        }
    }

    private var concurrencyHint: String {
        switch vm.ocrEngine {
        case .paddleVL:
            return "PaddleOCR-VL 只有一份 KV 缓存，始终逐张处理，这项设置对它不起作用。"
        case .paddleOCR:
            return "图片解码会真正并行；PaddleOCR 的模型推理仍逐张进行"
                 + "（避免多份模型抢占同一颗 CPU），但下一张的解码不再等待。"
        case .visionFast, .visionAccurate:
            return "多张图片会同时解码并交给 Apple Vision 识别，充分利用多核 CPU。"
        }
    }

    // MARK: - Building blocks

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
    private func settingSection<Content: View>(_ title: String,
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

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func noticeBox(_ text: String, tint: Color) -> some View {
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

    private func modelManagerLink(_ title: String) -> some View {
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

    private func toggleRow(isOn: Binding<Bool>, title: String, subtitle: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func valueSlider(_ title: String, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double,
                             hint text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
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
