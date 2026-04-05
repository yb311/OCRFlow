import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            DetailView()
        }
        .toolbar {
            toolbarContent
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(vm)
        }
        .frame(minWidth: 760, minHeight: 520)
        // Global drag-and-drop on the whole window
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropHelper.handle(providers: providers, vm: vm)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Center: progress
        ToolbarItem(placement: .principal) {
            if vm.isProcessing {
                HStack(spacing: 8) {
                    ProgressView(value: vm.totalProgress)
                        .tint(.accentColor)
                        .frame(width: 120)
                    Text("\(Int(vm.totalProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if !vm.items.isEmpty && vm.totalProgress > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("\(vm.completedCount)/\(vm.items.count) 已完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // Right group
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.isProcessing {
                Button {
                    vm.stopProcessing()
                } label: {
                    Label("停止", systemImage: "stop.circle")
                }
                .help("停止识别")
            } else {
                Button {
                    vm.startProcessing()
                } label: {
                    Label("开始识别", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.items.isEmpty || vm.items.allSatisfy { $0.status == .completed })
                .help("开始批量 OCR 识别")
            }

            Button {
                vm.exportResults()
            } label: {
                Label("导出结果", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.completedCount == 0)
            .help("导出所有识别结果为文本文件")

            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .help("识别设置")
        }
    }
}

// MARK: - Settings sheet

struct SettingsSheet: View {
    @EnvironmentObject var vm: OCRViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("设置")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // Tab bar
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = idx }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 16))
                            Text(tab.title)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selectedTab == idx ? Color.accentColor : Color.secondary)
                        .background(selectedTab == idx
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if selectedTab == idx {
                            Rectangle().fill(Color.accentColor).frame(height: 2)
                        }
                    }
                }
            }
            .background(.bar)

            Divider()

            // Tab content
            ScrollView {
                Group {
                    switch selectedTab {
                    case 0: recognitionTab
                    case 1: languageTab
                    case 2: textProcessingTab
                    case 3: exportTab
                    default: behaviorTab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 420, height: 500)
    }

    private let tabs: [(title: String, icon: String)] = [
        ("识别",   "text.viewfinder"),
        ("语言",   "globe"),
        ("文本",   "text.alignleft"),
        ("导出",   "square.and.arrow.up"),
        ("行为",   "gearshape.2"),
    ]

    // MARK: - Tab: Recognition

    private var recognitionTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSection("识别引擎") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(OCREngine.allCases) { engine in
                        Button {
                            vm.ocrEngine = engine
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: vm.ocrEngine == engine ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(vm.ocrEngine == engine ? Color.accentColor : Color.secondary)
                                    .font(.system(size: 15))
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.label)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                    Text(engine.hint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

            }
        }
    }

    // MARK: - Tab: Language

    private var languageTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSection("识别语言") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([
                        ("zh-Hans", "简体中文"),
                        ("zh-Hant", "繁体中文"),
                        ("en-US",   "英文"),
                        ("ja-JP",   "日文"),
                        ("ko-KR",   "韩文"),
                        ("fr-FR",   "法文"),
                        ("de-DE",   "德文"),
                        ("es-ES",   "西班牙文"),
                    ], id: \.0) { code, name in
                        Toggle(name, isOn: languageBinding(code))
                    }
                }
                hint("可同时勾选多种语言，Vision 会自动检测并优先识别靠前的语言。")
            }
        }
    }

    // MARK: - Tab: Text processing

    private var textProcessingTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSection("换行处理") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $vm.mergeLineBreaks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("合并为单行（不换行）")
                                .font(.callout)
                            Text("将所有换行替换为空格，输出连续段落")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(vm.removeEmptyLines && vm.mergeLineBreaks)

                    Toggle(isOn: $vm.removeEmptyLines) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("去除多余空行")
                                .font(.callout)
                            Text("将连续多个空行压缩为单个空行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(vm.mergeLineBreaks)
                }
            }

            settingSection("空白字符") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $vm.trimWhitespace) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("去除行首尾空格")
                                .font(.callout)
                            Text("清除每行两端多余的空白字符")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $vm.removeHyphenBreaks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("合并连字符换行")
                                .font(.callout)
                            Text("适合英文扫描件，自动拼合被断行分割的单词")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if vm.mergeLineBreaks || vm.removeEmptyLines || vm.trimWhitespace || vm.removeHyphenBreaks {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text("文本后处理仅影响新识别的结果，不会修改已有内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Tab: Export

    private var exportTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSection("文件分隔符") {
                Picker("", selection: $vm.exportSeparator) {
                    ForEach(OCRViewModel.ExportSeparator.allCases) { sep in
                        Text(sep.rawValue).tag(sep)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                hint("多个文件导出为同一文本时，各文件内容之间的分隔方式。")
            }

            settingSection("文件名标题") {
                Toggle("导出时包含文件名", isOn: $vm.exportIncludeFilename)
                hint("开启后每段内容前会加上「=== 文件名 ===」标题行。")
            }
        }
    }

    // MARK: - Tab: Behavior

    private var behaviorTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSection("自动化") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $vm.autoStartOnAdd) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("添加文件后自动开始识别")
                                .font(.callout)
                            Text("拖入或选择文件后立即开始批量处理")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $vm.skipCompleted) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("跳过已完成的文件")
                                .font(.callout)
                            Text("重新点击「开始识别」时，不重复处理已识别的文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func languageBinding(_ lang: String) -> Binding<Bool> {
        Binding(
            get: { vm.recognitionLanguages.contains(lang) },
            set: { enabled in
                if enabled {
                    if !vm.recognitionLanguages.contains(lang) { vm.recognitionLanguages.append(lang) }
                } else {
                    vm.recognitionLanguages.removeAll { $0 == lang }
                    if vm.recognitionLanguages.isEmpty { vm.recognitionLanguages.append("en-US") }
                }
            }
        )
    }
}
