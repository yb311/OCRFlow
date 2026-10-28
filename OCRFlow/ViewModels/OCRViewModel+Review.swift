import Foundation
import AppKit

extension OCRViewModel {

    // MARK: - Review

    /// Everything flagged for a person to look at, file by file, page by page,
    /// in reading order — the queue the review mode works through.
    var reviewEntries: [ReviewEntry] {
        items.filter { $0.status == .completed }.flatMap { item in
            item.pages.enumerated().flatMap { pageIndex, page in
                let pageNotes = page.notes.filter { $0.severity == .warning }.map { note in
                    ReviewEntry(itemID: item.id, fileName: item.fileName, page: pageIndex,
                                origin: .note(note), reason: note.reason)
                }
                let regions = page.blocks.indices
                    .filter { page.blocks[$0].review != nil }
                    .sorted { page.blocks[$0].readingOrder < page.blocks[$1].readingOrder }
                    .compactMap { index in
                        page.blocks[index].review.map {
                            ReviewEntry(itemID: item.id, fileName: item.fileName, page: pageIndex,
                                        origin: .region(index), reason: $0)
                        }
                    }
                return pageNotes + regions
            }
        }
    }

    /// Settles one flagged item without changing any text: the region, or the
    /// page note, has been looked at and is fine as it is.
    func resolveReview(_ entry: ReviewEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.itemID }),
              items[index].pages.indices.contains(entry.page) else { return }
        switch entry.origin {
        case let .region(block):
            guard items[index].pages[entry.page].blocks.indices.contains(block) else { return }
            items[index].pages[entry.page].blocks[block].review = nil
            items[index].pages[entry.page].blocks[block].alternative = nil
        case let .note(note):
            items[index].pages[entry.page].notes.removeAll { $0 == note }
        }
        store.save(items[index])
    }

    /// Clears every flag that asks a person to choose between two readings
    /// that say the same thing — left by earlier builds, which compared them
    /// character for character and took a moved line break for a difference.
    func settleEquivalentReadings() {
        for index in items.indices {
            var changed = false
            for page in items[index].pages.indices {
                for block in items[index].pages[page].blocks.indices {
                    let region = items[index].pages[page].blocks[block]
                    guard let alternative = region.alternative,
                          AlternativeReading.isEquivalent(alternative.text, region.text) else { continue }
                    items[index].pages[page].blocks[block].alternative = nil
                    items[index].pages[page].blocks[block].review = nil
                    changed = true
                }
            }
            if changed { store.save(items[index]) }
        }
    }

    /// Settles a flagged region with the text a person chose.
    ///
    /// Picking one of the two readings as it stands takes that reader's word
    /// for it — the region now says who read it, and nothing counts as
    /// corrected. Anything else typed in is a correction, kept beside what was
    /// recognised the way `correctBlock` keeps it.
    func settleRegion(itemID: UUID, page: Int, blockIndex: Int, text: String, chosenSource: PPTextSource?) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].pages.indices.contains(page),
              items[index].pages[page].blocks.indices.contains(blockIndex) else { return }
        var block = items[index].pages[page].blocks[blockIndex]
        if let chosenSource {
            block.text = text
            block.source = chosenSource
        } else if block.text != text {
            let original = block.recognisedText ?? block.text
            block.recognisedText = text == original ? nil : original
            block.text = text
        }
        block.review = nil
        block.alternative = nil
        items[index].pages[page].blocks[blockIndex] = block
        rebuildDocument(at: index)
        store.save(items[index])
    }

    /// Opens review on a file — at a given page, and region, when there is one
    /// flagged there.
    func startReview(itemID: UUID? = nil, page: Int? = nil, block: Int? = nil) {
        let entries = reviewEntries
        // Asked for no place in particular: carry on where review was left.
        if itemID == nil, let focus = reviewFocus, entries.contains(where: { $0.id == focus }) {
            mode = .review
            return
        }
        let match = entries.first { entry in
            (itemID == nil || entry.itemID == itemID) && (page == nil || entry.page == page)
                && (block == nil || entry.block == block)
        } ?? entries.first { $0.itemID == itemID } ?? entries.first
        reviewFocus = match?.id
        mode = .review
    }

    /// Leaves review for the document, turned to the page and region in question.
    func showInDocument(_ entry: ReviewEntry) {
        selectedIDs = [entry.itemID]
        documentFocus = DocumentFocus(itemID: entry.itemID, page: entry.page, block: entry.block)
        mode = .workspace
    }

    /// Rebuilds the text and the Markdown of every finished result.
    func rebuildDocuments() {
        for index in items.indices where items[index].status == .completed {
            rebuildDocument(at: index)
        }
    }

    func rebuildDocument(at index: Int) {
        let document = Self.assemble(items[index].pages, dropping: droppedLabels,
                                     inferHeadingLevels: vlConfig.inferHeadingLevels)
        items[index].ocrText = postProcess(document.text)
        items[index].markdown = document.markdown
    }

    /// The document a file's pages make, honouring the page-furniture
    /// preference. Pure, and deliberately not on the main actor.
    nonisolated static func assemble(_ pages: [PageResult], dropping: Set<PPLayoutLabel>,
                                     inferHeadingLevels: Bool) -> (text: String, markdown: String) {
        let parts = pages.map { $0.assembled(dropping: dropping, inferHeadingLevels: inferHeadingLevels) }
        let structured = pages.contains { $0.derivesFromBlocks || !$0.rawMarkdown.isEmpty }
        let text = parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let markdown = structured
            ? parts.map { $0.markdown.isEmpty ? $0.text : $0.markdown }
                .filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
            : ""
        return (text, markdown)
    }
}
