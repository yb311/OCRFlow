import SwiftUI
import NaturalLanguage
import Translation
import UniformTypeIdentifiers

/// Translates recognised documents with macOS's own translation, paragraph by
/// paragraph, and shows the result beside the original.
///
/// Apple's Translation framework runs on the device: nothing is uploaded, the
/// same promise the OCR makes. A language pair used for the first time asks
/// the system to download it, through the system's own prompt.
@available(macOS 15.0, *)
struct TranslationSheet: View {
    let items: [ImageItem]

    @Environment(\.dismiss) private var dismiss
    @AppStorage("translation.target") private var targetCode = "zh-Hans"
    @State private var configuration: TranslationSession.Configuration?
    /// Translations by item, one per paragraph.
    @State private var translations: [UUID: [String]] = [:]
    @State private var done = 0
    @State private var isTranslating = false
    @State private var failure: String?

    /// The languages offered, by the name they go by in Chinese.
    private static let targets: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"),
        ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский"),
    ]

    /// A document as the paragraphs it is translated in.
    ///
    /// Each paragraph is rejoined first: a line break where the page's line
    /// happened to end splits a sentence in two, and the translator then
    /// translates two halves. Tables keep their rows.
    static func paragraphs(of item: ImageItem) -> [String] {
        item.ocrText.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.contains("\t") ? $0 : PPDocumentAssembler.reflowed($0) }
    }

    private var totalParagraphs: Int { items.reduce(0) { $0 + Self.paragraphs(of: $1).count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(items.count == 1 ? "Translate “\(items[0].fileName)”" : "Translate \(items.count) Files")
                    .font(.headline)
                Spacer()
                Picker("Translate to", selection: $targetCode) {
                    ForEach(Self.targets, id: \.code) { Text($0.name).tag($0.code) }
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
    }

    private func start() {
        failure = nil
        translations = [:]
        done = 0
        // The language is worked out once, from everything there is to read.
        // Left to the framework, it is guessed paragraph by paragraph, and a
        // paragraph of names and formulas is a guess it refuses to make.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(items.map(\.ocrText).joined(separator: "\n"))
        guard let dominant = recognizer.dominantLanguage else {
            failure = String(localized: "Couldn't tell what language the text is in")
            return
        }
        let source = Locale.Language(identifier: dominant.rawValue)
        let target = Locale.Language(identifier: targetCode)
        guard source.minimalIdentifier != target.minimalIdentifier else {
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
