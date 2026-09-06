import SwiftUI

/// Downloads and removes the models the app does not ship with.
///
/// Everything here is optional: a fresh install already has the `tiny` and
/// `small` PP-OCRv6 tiers inside the bundle and works offline without ever
/// opening this sheet.
struct ModelManagerView: View {
    static let windowID = "model-manager"

    @ObservedObject var downloader: PPModelDownloader

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceSection
                tierSection
                vlSection
                languageSection
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - Sections

    private var sourceSection: some View {
        section("下载源") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $downloader.source) {
                    ForEach(PPModelCatalog.Source.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                caption("模型来自 Hugging Face。除 PaddleOCR-VL 的 Q4 量化档为社区上传外，其余均为 PaddlePaddle 官方仓库。若连接不畅可切换镜像源。")
                Button {
                    PPModelStore.ensureUserModelsDirectory()
                    NSWorkspace.shared.open(PPModelStore.userModelsDirectory)
                } label: {
                    Label("打开模型目录", systemImage: "folder").font(.callout)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var tierSection: some View {
        section("PP-OCRv6 模型") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(PPModelTier.allCases) { tier in
                    if tier.isBundled {
                        bundledRow(tier)
                    } else {
                        entryRow(PPModelCatalog.mediumTier, title: tier.label)
                    }
                }
                caption("PP-OCRv6 单模型覆盖 50 种语言：简体中文、繁体中文、英文、日文，以及 46 种拉丁语系语言。")
            }
        }
    }

    private var vlSection: some View {
        section("PaddleOCR-VL 1.6") {
            VStack(alignment: .leading, spacing: 12) {
                caption("0.9B 视觉语言模型。官方管线分两阶段：版面分析模型切分页面并判定阅读顺序，"
                        + "再由 VL 模型逐块识别，因此版面模型是必装项。两档权重任选其一即可。")
                ForEach(PPModelCatalog.vlEntries) { entry in
                    entryRow(entry, title: entry.name)
                }
            }
        }
    }

    private var languageSection: some View {
        section("其他语种识别器") {
            VStack(alignment: .leading, spacing: 12) {
                caption("PP-OCRv6 未发布以下文字的模型，改用 PP-OCRv5 单语种识别器。"
                        + "文本检测与语种无关，安装后仍由 PP-OCRv6 检测器定位文字。")
                ForEach(PPModelCatalog.languageRecognizers) { entry in
                    entryRow(entry, title: entry.name)
                }
            }
        }
    }

    // MARK: - Rows

    private func bundledRow(_ tier: PPModelTier) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tier.label).font(.callout)
                Text(tier.hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("已内置", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private func entryRow(_ entry: PPModelCatalog.Entry, title: String) -> some View {
        let isDownloading = downloader.isDownloading(entry)
        let isInstalled = entry.isInstalled

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout)
                    Text("\(entry.detail) · 约 \(sizeText(entry.approximateBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDownloading {
                    Button("取消") { downloader.cancel(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if isInstalled {
                    Button("删除") { downloader.remove(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("下载") { downloader.download(entry) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            if isDownloading {
                ProgressView(value: downloader.progress[entry.id] ?? 0)
                    .progressViewStyle(.linear)
            } else if isInstalled {
                Label("已安装", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let error = downloader.errors[entry.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb < 1024 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1024)
    }
}
