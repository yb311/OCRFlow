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
        section("Download Source") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $downloader.source) {
                    ForEach(PPModelCatalog.Source.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                caption("Models come from Hugging Face. Apart from the community-uploaded Q4 quantization of PaddleOCR-VL, all are from official PaddlePaddle repositories. Switch to the mirror if the connection is poor.")
                Button {
                    PPModelStore.ensureUserModelsDirectory()
                    NSWorkspace.shared.open(PPModelStore.userModelsDirectory)
                } label: {
                    Label("Open Models Folder", systemImage: "folder").font(.callout)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var tierSection: some View {
        section("PP-OCRv6 Models") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(PPModelTier.allCases) { tier in
                    if tier.isBundled {
                        bundledRow(tier)
                    } else {
                        entryRow(PPModelCatalog.mediumTier, title: tier.label)
                    }
                }
                caption("A single PP-OCRv6 model covers 50 languages: Simplified Chinese, Traditional Chinese, English, Japanese, and 46 Latin-script languages.")
            }
        }
    }

    private var vlSection: some View {
        section("PaddleOCR-VL 1.6") {
            VStack(alignment: .leading, spacing: 12) {
                caption("A 0.9B vision-language model. The official pipeline has two stages: a layout model splits the page and decides the reading order, then the VL model reads each block, so the layout model is required. Either set of weights will do.")
                ForEach(PPModelCatalog.vlEntries) { entry in
                    entryRow(entry, title: entry.name)
                }
            }
        }
    }

    private var languageSection: some View {
        section("Other Language Recognizers") {
            VStack(alignment: .leading, spacing: 12) {
                caption("PP-OCRv6 has no models for the scripts below, so PP-OCRv5 single-language recognizers are used instead. Text detection is language-independent: once installed, the PP-OCRv6 detector still locates the text.")
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
            Label("Built in", systemImage: "checkmark.seal.fill")
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
                    Text("\(entry.detail) · About \(sizeText(entry.approximateBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDownloading {
                    Button("Cancel") { downloader.cancel(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if isInstalled {
                    Button("Delete") { downloader.remove(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Download") { downloader.download(entry) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            if isDownloading {
                ProgressView(value: downloader.progress[entry.id] ?? 0)
                    .progressViewStyle(.linear)
            } else if isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
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
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
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

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func sizeText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
