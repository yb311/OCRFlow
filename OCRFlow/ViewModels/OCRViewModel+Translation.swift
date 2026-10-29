import Foundation

extension OCRViewModel {

    // MARK: - Translation

    @available(macOS 15.0, *)
    var translator: AutoTranslator {
        // Set in the initialiser whenever this version is available.
        translatorBox as! AutoTranslator
    }

    /// Queues a finished result to be translated in the background. Does
    /// nothing before macOS 15, which has no on-device translation to use.
    func translate(_ item: ImageItem, into target: String? = nil) {
        guard #available(macOS 15.0, *) else { return }
        translator.enqueue(item, target: target ?? translationTarget)
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
        if #available(macOS 15.0, *) { translator.cancel(ids) }
    }
}
