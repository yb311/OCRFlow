import Foundation
import NaturalLanguage
import Translation

/// A document's translation into one language, paragraph by paragraph.
///
/// Kept by the paragraph it translates rather than by position: a correction
/// or a changed setting rebuilds the text, and only the paragraphs that
/// actually changed then lose their translation — the rest still line up.
struct DocumentTranslation: Codable, Equatable {
    /// The language translated into, as the user picked it (`zh-Hans`).
    var target: String
    /// Translations by the original paragraph.
    var paragraphs: [String: String] = [:]

    /// The languages offered, by the name they go by in themselves.
    static let targets: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"),
        ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский"),
    ]

    /// A document as the paragraphs it is translated in.
    ///
    /// Each paragraph is rejoined first: a line break where the page's line
    /// happened to end splits a sentence in two, and the translator then
    /// translates two halves. Tables keep their rows.
    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.contains("\t") ? $0 : PPDocumentAssembler.reflowed($0) }
    }

    /// The language a text is mostly in.
    ///
    /// Worked out once, from everything there is to read. Left to the
    /// framework, it is guessed paragraph by paragraph, and a paragraph of
    /// names and formulas is a guess it refuses to make.
    static func language(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    /// True when `code` names the language the text is already in.
    static func isSameLanguage(_ source: Locale.Language, as code: String) -> Bool {
        source.minimalIdentifier == Locale.Language(identifier: code).minimalIdentifier
    }

    /// The paragraphs of `item` with no translation into `target` yet.
    static func untranslated(in item: ImageItem, target: String) -> [String] {
        let done = item.translation?.target == target ? item.translation?.paragraphs ?? [:] : [:]
        var seen = Set<String>()
        return paragraphs(of: item.ocrText).filter { done[$0] == nil && seen.insert($0).inserted }
    }

    /// The translated document, optionally interleaved with the original.
    func document(of text: String, bilingual: Bool) -> String {
        Self.paragraphs(of: text).map { original in
            let translated = paragraphs[original] ?? ""
            return bilingual ? "\(original)\n\n\(translated)" : translated
        }.joined(separator: "\n\n")
    }
}

/// Translates finished results in the background, one after another, with
/// macOS's own on-device translation.
///
/// On macOS 15 a translation session can only be had from a view, through
/// `translationTask`, so the work is driven from `AutoTranslationHost`, an
/// invisible view in the main window: this sets the configuration, the view
/// hands over a session for it, and `run` works through every document
/// waiting in that language. Documents in another language get a session of
/// their own once it is done.
@available(macOS 15.0, *)
@MainActor
final class AutoTranslator: ObservableObject {
    @Published private(set) var configuration: TranslationSession.Configuration?

    /// Where documents are read from and their translations go.
    weak var owner: OCRViewModel?

    private struct Job {
        let id: UUID
        let source: Locale.Language
        let target: String
    }

    private var waiting: [Job] = []
    /// The target of the session asked for, kept as the user picked it:
    /// `Locale.Language` reduces `zh-Hans` to plain `zh`.
    private var sessionTarget: String?
    private var isRunning = false

    /// Queues a finished document for translation into `target`, if it has
    /// anything left to translate and is not in that language already.
    func enqueue(_ item: ImageItem, target: String) {
        guard item.isExportable, !waiting.contains(where: { $0.id == item.id }),
              !DocumentTranslation.untranslated(in: item, target: target).isEmpty,
              let source = DocumentTranslation.language(of: item.ocrText),
              !DocumentTranslation.isSameLanguage(source, as: target) else { return }
        waiting.append(Job(id: item.id, source: source, target: target))
        owner?.translatingIDs.insert(item.id)
        startIfIdle()
    }

    /// Forgets documents that left the list.
    func cancel(_ ids: Set<UUID>) {
        waiting.removeAll { ids.contains($0.id) }
    }

    private func startIfIdle() {
        guard !isRunning, let next = waiting.first else { return }
        isRunning = true
        sessionTarget = next.target
        let target = Locale.Language(identifier: next.target)
        if configuration?.source == next.source, configuration?.target == target {
            // The same pair again: the task only runs when asked anew.
            configuration?.invalidate()
        } else {
            configuration = .init(source: next.source, target: target)
        }
    }

    /// Translates every waiting document the session's language pair fits.
    func run(_ session: TranslationSession) async {
        // The session is handed to this task and used by nothing else, one
        // call after another; the framework just does not mark it Sendable.
        nonisolated(unsafe) let session = session
        defer {
            isRunning = false
            startIfIdle()
        }
        guard let source = configuration?.source, let target = sessionTarget else { return }
        let fits = { (job: Job) in job.source == source && job.target == target }

        do {
            try await session.prepareTranslation()
        } catch {
            // Declined, or the pair is not one macOS translates: nothing in
            // this language will get further this time.
            if Task.isCancelled { return }
            for job in waiting where fits(job) { owner?.translatingIDs.remove(job.id) }
            waiting.removeAll(where: fits)
            owner?.translationFailure = String(localized: "Translation didn't finish: \(error.localizedDescription)")
            return
        }

        while let index = waiting.firstIndex(where: fits) {
            let job = waiting[index]
            guard let item = owner?.items.first(where: { $0.id == job.id }), item.isExportable else {
                waiting.remove(at: index)
                owner?.translatingIDs.remove(job.id)
                continue
            }
            let originals = DocumentTranslation.untranslated(in: item, target: target)
            let requests = originals.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)")
            }
            var translated: [String: String] = [:]
            do {
                for try await response in session.translate(batch: requests) {
                    if let i = response.clientIdentifier.flatMap(Int.init), originals.indices.contains(i) {
                        translated[originals[i]] = response.targetText
                    }
                }
            } catch {
                // The window closed under it: the document stays queued for
                // when the session comes back.
                if Task.isCancelled { return }
                owner?.translationFailure = String(localized: "Translation didn't finish: \(error.localizedDescription)")
            }
            waiting.removeAll { $0.id == job.id }
            owner?.translatingIDs.remove(job.id)
            if !translated.isEmpty {
                owner?.translationFailure = nil
                owner?.addTranslation(translated, target: target, to: job.id)
            }
        }
    }
}
