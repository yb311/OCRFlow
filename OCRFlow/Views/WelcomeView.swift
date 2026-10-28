import SwiftUI

/// Shown on the first launch: what the app does out of the box, and the one
/// download that makes the default engine whole.
///
/// The app reads text offline from the first moment, with the PP-OCRv6
/// models inside the bundle. Tables, formulas and multi-column layouts need
/// the layout model and PaddleOCR-VL, about a gigabyte, which cannot ship in
/// the download — so the choice is offered here, once, instead of being found
/// out from a page of flattened tables.
struct WelcomeView: View {
    static let seenKey = "OCRFlow.hasSeenWelcome"

    @ObservedObject var downloader: PPModelDownloader
    @Environment(\.dismiss) private var dismiss

    private let entries = [PPModelCatalog.layoutModel, PPModelCatalog.vlQuantized]

    private var installed: Bool {
        _ = downloader.inventoryVersion
        return entries.allSatisfy(\.isInstalled)
    }

    private var downloading: Bool {
        entries.contains(where: downloader.isDownloading)
    }

    private var totalBytes: Int64 {
        entries.filter { !$0.isInstalled }.map(\.approximateBytes).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to OCRFlow").font(.title2.weight(.semibold))
                    Text("Turn scans, photos and PDFs into text you can search and edit.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                point("tray.and.arrow.down", "Drop in images, PDFs or whole folders",
                      "Then press Start Recognition (⌘R). Results can be checked, corrected and exported.")
                point("lock", "Everything stays on your Mac",
                      "Recognition runs locally. Files and text are never uploaded.")
                point("checkmark.circle", "Ready to use now",
                      "The built-in PP-OCRv6 models read Chinese, English, Japanese and 46 more languages, offline.")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recommended: tables, formulas and complex layouts")
                        .font(.headline)
                    Text("Smart Layering, the default engine, uses a layout model to find tables, formulas and columns, and PaddleOCR-VL to read them. Without these, every page is read as plain lines of text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    downloadState
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("Models can be added or removed later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(downloading ? "Continue in Background" : "Start Using OCRFlow") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onDisappear { UserDefaults.standard.set(true, forKey: Self.seenKey) }
    }

    @ViewBuilder
    private var downloadState: some View {
        if installed {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if downloading {
            ForEach(entries.filter { downloader.isDownloading($0) }) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.caption)
                    ProgressView(value: downloader.progress[entry.id] ?? 0)
                        .accessibilityLabel(entry.name)
                }
            }
        } else {
            HStack {
                Button("Download (\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)))") {
                    for entry in entries where !entry.isInstalled { downloader.download(entry) }
                }
                Picker("From", selection: $downloader.source) {
                    ForEach(PPModelCatalog.Source.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .fixedSize()
            }
            ForEach(entries) { entry in
                if let error = downloader.errors[entry.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
