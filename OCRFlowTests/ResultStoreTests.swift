import XCTest
@testable import OCRFlow

final class ResultStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ResultStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResultStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = ResultStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func page(_ text: String) -> PageResult {
        PageResult(size: CGSize(width: 100, height: 50), rawText: text)
    }

    func testQueueRoundTripsWithResults() {
        var done = ImageItem(url: URL(fileURLWithPath: "/a/done.png"))
        done.status = .completed
        done.engine = .paddleOCR
        done.pages = [page("hello")]
        var failed = ImageItem(url: URL(fileURLWithPath: "/a/bad.png"))
        failed.status = .failed
        failed.errorMessage = "broken"
        var running = ImageItem(url: URL(fileURLWithPath: "/a/running.png"))
        running.status = .processing

        store.save(done)
        store.saveQueue([done, failed, running])

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), [done.id, failed.id, running.id])
        XCTAssertEqual(loaded[0].status, .completed)
        XCTAssertEqual(loaded[0].pages.first?.rawText, "hello")
        XCTAssertEqual(loaded[0].engine, .paddleOCR)
        XCTAssertEqual(loaded[1].errorMessage, "broken")
        // A file being read when the app went away was not read.
        XCTAssertEqual(loaded[2].status, .pending)
    }

    func testCompletedItemWhoseResultIsGoneIsReadAgain() {
        var item = ImageItem(url: URL(fileURLWithPath: "/a/x.png"))
        item.status = .completed
        store.saveQueue([item])
        XCTAssertEqual(store.load().first?.status, .pending)
    }

    func testPartialPagesResumeAStoppedDocument() {
        store.savePartialPage(page("one"), index: 0, for: "key")
        store.savePartialPage(page("two"), index: 1, for: "key")
        XCTAssertEqual(store.partialPageCount(for: "key"), 2)
        XCTAssertEqual(store.partialPages(for: "key")[1]?.rawText, "two")

        var item = ImageItem(url: URL(fileURLWithPath: "/a/long.pdf"))
        item.status = .cancelled
        item.resume = ResumePoint(key: "key", total: 10, read: 2)
        store.saveQueue([item])
        XCTAssertEqual(store.load().first?.resume, ResumePoint(key: "key", total: 10, read: 2))

        store.removePartial(for: "key")
        XCTAssertEqual(store.partialPageCount(for: "key"), 0)
    }

    func testCacheKeyDependsOnBytesAndSettings() throws {
        let file = directory.appendingPathComponent("f.bin")
        try Data("abc".utf8).write(to: file)
        let a = try XCTUnwrap(ResultStore.cacheKey(for: file, fingerprint: "ppocr"))
        XCTAssertEqual(a, ResultStore.cacheKey(for: file, fingerprint: "ppocr"))
        XCTAssertNotEqual(a, ResultStore.cacheKey(for: file, fingerprint: "vl"))

        // The same bytes under another name are the same file.
        let copy = directory.appendingPathComponent("renamed.bin")
        try FileManager.default.copyItem(at: file, to: copy)
        XCTAssertEqual(a, ResultStore.cacheKey(for: copy, fingerprint: "ppocr"))

        try Data("abd".utf8).write(to: file)
        XCTAssertNotEqual(a, ResultStore.cacheKey(for: file, fingerprint: "ppocr"))
        XCTAssertNil(ResultStore.cacheKey(for: directory.appendingPathComponent("missing"), fingerprint: ""))
    }

    func testCacheRoundTrip() {
        XCTAssertNil(store.cachedPages(for: "k"))
        store.cache([page("cached")], for: "k")
        _ = store.load()   // waits for the store's pending writes
        XCTAssertEqual(store.cachedPages(for: "k")?.first?.rawText, "cached")
    }

    func testPruneResultsKeepsOnlyListedItems() {
        var kept = ImageItem(url: URL(fileURLWithPath: "/k.png"))
        kept.status = .completed
        kept.pages = [page("k")]
        var dropped = ImageItem(url: URL(fileURLWithPath: "/d.png"))
        dropped.status = .completed
        dropped.pages = [page("d")]
        store.save(kept)
        store.save(dropped)
        store.pruneResults(keeping: [kept.id])
        store.saveQueue([kept, dropped])
        let loaded = store.load()
        XCTAssertEqual(loaded[0].status, .completed)
        XCTAssertEqual(loaded[1].status, .pending)
    }
}
