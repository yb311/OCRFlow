import Foundation

extension OCRViewModel {

    // MARK: - Translation

    /// Queues a finished result to be translated in the background.
    func translate(_ item: ImageItem, into target: String? = nil) {
        translator.enqueue(item, target: target ?? translationTarget)
    }

    /// Replaces a target language macOS does not offer as written — the
    /// default worked out from the system language, or one saved by an
    /// earlier build — with the form it does offer, so the picker shows no
    /// stray entry and translation asks for a language that exists.
    func validateTranslationTarget() {
        Task {
            let supported = await DocumentTranslation.supportedTargets()
            if let target = DocumentTranslation.target(translationTarget, among: supported),
               target != translationTarget {
                translationTarget = target
            }
        }
    }

    /// Adds translated paragraphs to a result, keeping what it already had
    /// in the same language.
    func addTranslation(_ paragraphs: [String: String], target: String, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var translation = DocumentTranslation(target: target)
        if let kept = items[index].translation, kept.target == target { translation = kept }
        translation.paragraphs.merge(paragraphs) { _, new in new }
        // Paragraphs the text no longer has are dropped, so a document
        // edited many times does not carry every version along.
        let current = Set(DocumentTranslation.paragraphs(of: items[index].ocrText))
        translation.paragraphs = translation.paragraphs.filter { current.contains($0.key) }
        items[index].translation = translation
        store.saveTranslation(translation, for: id)
        if watchedAwaitingTranslation.remove(id) != nil { exportWatchedTranslation(items[index]) }
    }

    /// Stops translating results that left the list.
    func forgetTranslations(_ ids: Set<UUID>) {
        translatingIDs.subtract(ids)
        watchedAwaitingTranslation.subtract(ids)
        translator.cancel(ids)
    }
}
