import Foundation
import Testing
@testable import OCRFlow

final class ResultStoreTests {

    private let directory = URL.temporaryDirectory
        .appending(path: "ResultStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let store: ResultStore

    init() {
        store = ResultStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func page(_ text: String) -> PageResult {
        PageResult(size: CGSize(width: 100, height: 50), rawText: text)
    }

    @Test func queueRoundTripsWithResults() {
        var done = ImageItem(url: URL(filePath: "/a/done.png"))
        done.status = .completed
        done.engine = .paddleOCR
        done.pages = [page("hello")]
        var failed = ImageItem(url: URL(filePath: "/a/bad.png"))
        failed.status = .failed
        failed.errorMessage = "broken"
        var running = ImageItem(url: URL(filePath: "/a/running.png"))
        running.status = .processing

        store.save(done)
        store.saveQueue([done, failed, running])

        let loaded = store.load()
        #expect(loaded.map(\.id) == [done.id, failed.id, running.id])
        #expect(loaded[0].status == .completed)
        #expect(loaded[0].pages.first?.rawText == "hello")
        #expect(loaded[0].engine == .paddleOCR)
        #expect(loaded[1].errorMessage == "broken")
        // A file being read when the app went away was not read.
        #expect(loaded[2].status == .pending)
    }

    @Test func completedItemWhoseResultIsGoneIsReadAgain() {
        var item = ImageItem(url: URL(filePath: "/a/x.png"))
        item.status = .completed
        store.saveQueue([item])
        #expect(store.load().first?.status == .pending)
    }

    @Test func partialPagesResumeAStoppedDocument() {
        store.savePartialPage(page("one"), index: 0, for: "key")
        store.savePartialPage(page("two"), index: 1, for: "key")
        #expect(store.partialPageCount(for: "key") == 2)
        #expect(store.partialPages(for: "key")[1]?.rawText == "two")

        var item = ImageItem(url: URL(filePath: "/a/long.pdf"))
        item.status = .cancelled
        item.resume = ResumePoint(key: "key", total: 10, read: 2)
        store.saveQueue([item])
        #expect(store.load().first?.resume == ResumePoint(key: "key", total: 10, read: 2))

        store.removePartial(for: "key")
        #expect(store.partialPageCount(for: "key") == 0)
    }

    @Test func cacheKeyDependsOnBytesAndSettings() throws {
        let file = directory.appending(path: "f.bin")
        try Data("abc".utf8).write(to: file)
        let a = try #require(ResultStore.cacheKey(for: file, fingerprint: "ppocr"))
        #expect(a == ResultStore.cacheKey(for: file, fingerprint: "ppocr"))
        #expect(a != ResultStore.cacheKey(for: file, fingerprint: "vl"))

        // The same bytes under another name are the same file.
        let copy = directory.appending(path: "renamed.bin")
        try FileManager.default.copyItem(at: file, to: copy)
        #expect(a == ResultStore.cacheKey(for: copy, fingerprint: "ppocr"))

        try Data("abd".utf8).write(to: file)
        #expect(a != ResultStore.cacheKey(for: file, fingerprint: "ppocr"))
        #expect(ResultStore.cacheKey(for: directory.appending(path: "missing"), fingerprint: "") == nil)
    }

    @Test func translationIsKeptWithTheResultAndGoesWithIt() {
        var done = ImageItem(url: URL(filePath: "/a/done.png"))
        done.status = .completed
        done.pages = [page("hello")]
        store.save(done)
        store.saveTranslation(DocumentTranslation(target: "zh-Hans", paragraphs: ["hello": "你好"]), for: done.id)
        store.saveQueue([done])

        #expect(store.load().first?.translation?.paragraphs["hello"] == "你好")

        store.remove([done.id])
        store.saveQueue([done])
        #expect(store.load().first?.translation == nil)
    }

    @Test func cacheRoundTrip() {
        #expect(store.cachedPages(for: "k") == nil)
        store.cache([page("cached")], for: "k")
        _ = store.load()   // waits for the store's pending writes
        #expect(store.cachedPages(for: "k")?.first?.rawText == "cached")
    }

    @Test func pruneResultsKeepsOnlyListedItems() {
        var kept = ImageItem(url: URL(filePath: "/k.png"))
        kept.status = .completed
        kept.pages = [page("k")]
        var dropped = ImageItem(url: URL(filePath: "/d.png"))
        dropped.status = .completed
        dropped.pages = [page("d")]
        store.save(kept)
        store.save(dropped)
        store.pruneResults(keeping: [kept.id])
        store.saveQueue([kept, dropped])
        let loaded = store.load()
        #expect(loaded[0].status == .completed)
        #expect(loaded[1].status == .pending)
    }
}
