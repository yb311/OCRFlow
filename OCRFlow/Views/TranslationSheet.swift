import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Translates recognised documents with macOS's own translation, paragraph by
/// paragraph, and shows the result beside the original.
///
/// Apple's Translation framework runs on the device: nothing is uploaded, the
/// same promise the OCR makes. A language pair used for the first time asks
/// the system to download it, through the system's own prompt.
///
/// What it translates is kept with the result, so a translation made here, or
/// in the background after recognition, is there the next time it opens.
@available(macOS 15.0, *)
struct TranslationSheet: View {
    let items: [ImageItem]

    @EnvironmentObject private var vm: OCRViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: TranslationSession.Configuration?
    /// Translations by item, one per paragraph.
    @State private var translations: [UUID: [String]] = [:]
    @State private var done = 0
    @State private var isTranslating = false
    @State private var failure: String?

    private var targetCode: String { vm.translationTarget }

    static func paragraphs(of item: ImageItem) -> [String] {
        DocumentTranslation.paragraphs(of: item.ocrText)
    }

    private var totalParagraphs: Int { items.reduce(0) { $0 + Self.paragraphs(of: $1).count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(items.count == 1 ? "Translate “\(items[0].fileName)”" : "Translate \(items.count) Files")
                    .font(.headline)
                Spacer()
                Picker("Translate to", selection: $vm.translationTarget) {
                    ForEach(DocumentTranslation.targets, id: \.code) { Text($0.name).tag($0.code) }
                }
                .fixedSize()
                .disabled(isTranslating)
                Button(isTranslating ? "Translating…" : "Translate") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTranslating || totalParagraphs == 0)
            }
            .padding(16)

            if isTranslating {
                ProgressView(value: Double(done), total: Double(max(totalParagraphs, 1)))
                    .padding(.horizontal, 16)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
            Divider().padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        if items.count > 1 {
                            Text(item.fileName).font(.headline).padding(.top, 6)
                        }
                        let originals = Self.paragraphs(of: item)
                        let translated = translations[item.id] ?? []
                        ForEach(Array(originals.enumerated()), id: \.offset) { index, original in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(original)
                                    .foregroundStyle(.secondary)
                                if translated.indices.contains(index) {
                                    Text(translated[index])
                                }
                            }
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Text("Uses macOS's built-in translation on this Mac; nothing is uploaded. The first time you use a language, macOS asks to download it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Translation") { copyTranslation() }
                    .disabled(translations.isEmpty)
                Button("Export Bilingual…") { export(bilingual: true) }
                    .disabled(translations.isEmpty)
                Button("Export Translation…") { export(bilingual: false) }
                    .disabled(translations.isEmpty)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 620)
        .translationTask(configuration) { session in
            await translate(with: session)
        }
        .onAppear(perform: showKept)
        .onChange(of: vm.translationTarget) { _, _ in showKept() }
    }

    /// Shows what was translated into the chosen language before.
    private func showKept() {
        guard !isTranslating else { return }
        failure = nil
        translations = [:]
        for item in items {
            guard let current = vm.items.first(where: { $0.id == item.id }),
                  let kept = current.translation, kept.target == targetCode else { continue }
            let paragraphs = Self.paragraphs(of: item)
            guard paragraphs.contains(where: { kept.paragraphs[$0] != nil }) else { continue }
            translations[item.id] = paragraphs.map { kept.paragraphs[$0] ?? "" }
        }
    }

    private func start() {
        failure = nil
        translations = [:]
        done = 0
        guard let source = DocumentTranslation.language(of: items.map(\.ocrText).joined(separator: "\n")) else {
            failure = String(localized: "Couldn't tell what language the text is in")
            return
        }
        let target = Locale.Language(identifier: targetCode)
        guard !DocumentTranslation.isSameLanguage(source, as: targetCode) else {
            failure = String(localized: "The text is already in the selected language")
            return
        }
        if configuration?.source == source, configuration?.target == target {
            // The same pair again: the task only runs when asked anew.
            configuration?.invalidate()
        } else {
            configuration = .init(source: source, target: target)
        }
    }

    private func translate(with session: TranslationSession) async {
        // The session is handed to this task and used by nothing else, one
        // call after another; the framework just does not mark it Sendable.
        nonisolated(unsafe) let session = session
        isTranslating = true
        defer { isTranslating = false }
        do {
            try await session.prepareTranslation()
            for item in items {
                let paragraphs = Self.paragraphs(of: item)
                guard !paragraphs.isEmpty else { continue }
                let requests = paragraphs.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)")
                }
                var result = [String](repeating: "", count: paragraphs.count)
                for try await response in session.translate(batch: requests) {
                    if let index = response.clientIdentifier.flatMap(Int.init), result.indices.contains(index) {
                        result[index] = response.targetText
                    }
                    done += 1
                    translations[item.id] = result
                }
                vm.addTranslation(Dictionary(zip(paragraphs, result), uniquingKeysWith: { first, _ in first })
                                    .filter { !$0.value.isEmpty },
                                  target: targetCode, to: item.id)
            }
        } catch {
            failure = String(localized: "Translation didn't finish: \(error.localizedDescription)")
        }
    }

    /// One file's translation, optionally interleaved with the original.
    private func document(for item: ImageItem, bilingual: Bool) -> String {
        let originals = Self.paragraphs(of: item)
        let translated = translations[item.id] ?? []
        return originals.indices.map { index in
            let translation = translated.indices.contains(index) ? translated[index] : ""
            return bilingual ? "\(originals[index])\n\n\(translation)" : translation
        }.joined(separator: "\n\n")
    }

    private func copyTranslation() {
        let text = items.map { document(for: $0, bilingual: false) }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(bilingual: Bool) {
        let suffix = bilingual ? String(localized: "_bilingual") : String(localized: "_translation")
        if items.count == 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(items[0].fileName)\(suffix).md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try document(for: items[0], bilingual: bilingual).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var failures: [String] = []
        for item in items where translations[item.id] != nil {
            let url = folder.appendingPathComponent("\(item.fileName)\(suffix).md")
            do {
                try document(for: item, bilingual: bilingual).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                failures.append(String(localized: "\(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }
        if failures.isEmpty {
            NSWorkspace.shared.open(folder)
        } else {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(failures.count) files couldn't be exported")
            alert.informativeText = failures.prefix(8).joined(separator: "\n")
            alert.runModal()
        }
    }
}

/// Gives the background translator its sessions. Invisible; it sits in the
/// main window because a translation session can only be had from a view.
@available(macOS 15.0, *)
struct AutoTranslationHost: View {
    @ObservedObject var translator: AutoTranslator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(translator.configuration) { session in
                await translator.run(session)
            }
    }
}

/// A result's translation beside the original, paragraph by paragraph.
struct TranslationPane: View {
    let item: ImageItem
    let isTranslating: Bool

    var body: some View {
        let translation = item.translation
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if isTranslating {
                    Label("Translating…", systemImage: "character.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(DocumentTranslation.paragraphs(of: item.ocrText).enumerated()), id: \.offset) { _, original in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(original)
                            .foregroundStyle(.secondary)
                        if let translated = translation?.paragraphs[original] {
                            Text(translated)
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }
}
