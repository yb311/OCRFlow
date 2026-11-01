import SwiftUI

/// Downloads and removes the models the app does not ship with.
///
/// Everything here is optional: a fresh install already has the `tiny` and
/// `small` PP-OCRv6 tiers inside the bundle and works offline without ever
/// opening this sheet.
struct ModelManagerView: View {
    static let windowID = "model-manager"

    @Bindable var downloader: PPModelDownloader

    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceSection
                tierSection
                vlSection
                languageSection
            }
            .padding(20)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // Opens as tall as what it lists, and can be made smaller or larger.
        .frame(minWidth: 560, idealWidth: 620, minHeight: 320, idealHeight: contentHeight)
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
                caption("Models are downloaded from Hugging Face. If downloading is slow, switch to the mirror.")
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
        section("Text Recognition") {
            VStack(alignment: .leading, spacing: 12) {
                caption("PP-OCRv6. One model reads 50 languages: Simplified and Traditional Chinese, English, Japanese and 46 Latin-script languages.")
                ForEach(PPModelTier.allCases) { tier in
                    if tier.isBundled {
                        row(title: tier.label, detail: tier.hint) {
                            Label("Built in", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    } else {
                        entryRow(PPModelCatalog.mediumTier, title: tier.label, detail: PPModelCatalog.mediumTier.detail)
                    }
                }
            }
        }
    }

    private var vlSection: some View {
        section("Tables, Formulas and Charts") {
            VStack(alignment: .leading, spacing: 12) {
                caption("PaddleOCR-VL 1.6 reads the blocks that layout analysis finds on a page. Download layout analysis and one of the two models.")
                ForEach(PPModelCatalog.vlEntries) { entry in
                    entryRow(entry, title: entry.name, detail: entry.detail)
                }
            }
        }
    }

    private var languageSection: some View {
        section("Other Languages") {
            VStack(alignment: .leading, spacing: 12) {
                caption("For scripts the built-in model can't read. Once one is downloaded, choose it as the recognition language in Settings.")
                ForEach(PPModelCatalog.languageRecognizers) { entry in
                    entryRow(entry, title: entry.name, detail: nil)
                }
            }
        }
    }

    // MARK: - Rows

    /// A name and what it is on the left; on the right, where it stands and
    /// what can be done — the same place in every row.
    private func row<Trailing: View>(title: String, detail: String?,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) { trailing() }
        }
    }

    private func entryRow(_ entry: PPModelCatalog.Entry, title: String, detail: String?) -> some View {
        let isDownloading = downloader.isDownloading(entry)
        let isInstalled = entry.isInstalled
        let size = String(localized: "About \(sizeText(entry.approximateBytes))")

        return VStack(alignment: .leading, spacing: 6) {
            row(title: title, detail: detail.map { "\($0) · \(size)" } ?? size) {
                if isDownloading {
                    Button("Cancel") { downloader.cancel(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
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
