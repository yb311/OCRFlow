import XCTest
@testable import OCRFlow

final class HistoryTests: XCTestCase {

    private var directory: URL!
    private var store: ResultStore!
    private var history: HistoryIndex { store.history }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryTests-\(UUID().uuidString)", isDirectory: true)
        store = ResultStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func finished(_ name: String, text: String) -> ImageItem {
        var item = ImageItem(url: URL(fileURLWithPath: "/docs/\(name)"))
        item.status = .completed
        item.engine = .auto
        item.pages = [PageResult(size: CGSize(width: 10, height: 10), rawText: text)]
        item.ocrText = text
        return item
    }

    func testFindsChineseAndEnglishPhrases() {
        let contract = finished("合同.pdf", text: "甲方应于二〇二四年三月一日前支付货款人民币壹万元整。")
        let paper = finished("paper.pdf", text: "Attention is all you need. The Transformer uses self-attention.")
        store.save(contract, isNewReading: true)
        store.save(paper, isNewReading: true)

        XCTAssertEqual(history.search("支付货款").map(\.id), [contract.id])
        XCTAssertEqual(history.search("self-attention").map(\.id), [paper.id])
        XCTAssertEqual(history.search("TRANSFORMER").map(\.id), [paper.id])
        // A file is found by its name too.
        XCTAssertEqual(history.search("paper").map(\.id), [paper.id])
        XCTAssertTrue(history.search("不存在的词").isEmpty)
        // A quote in the query is searched for, not parsed.
        XCTAssertTrue(history.search("\"货款").isEmpty)
    }

    func testShortQueriesStillMatch() {
        let contract = finished("合同.pdf", text: "甲方应支付货款。")
        store.save(contract, isNewReading: true)
        XCTAssertEqual(history.search("货款").map(\.id), [contract.id])
        XCTAssertEqual(history.search("甲").map(\.id), [contract.id])
        XCTAssertEqual(history.search("%").count, 0)
    }

    func testSnippetMarksTheMatch() throws {
        let item = finished("a.txt", text: String(repeating: "前文", count: 50) + "关键内容" + String(repeating: "后文", count: 50))
        store.save(item, isNewReading: true)
        let (open, close) = HistoryIndex.snippetMarks
        for query in ["关键内容", "关键"] {
            let snippet = try XCTUnwrap(history.search(query).first?.snippet)
            XCTAssertTrue(snippet.contains(open + query + close), snippet)
            XCTAssertLessThan(snippet.count, 200)
        }
    }

    func testNewestFirstAndCorrectionsKeepTheDate() throws {
        let first = finished("1.png", text: "one")
        store.save(first, isNewReading: true)
        Thread.sleep(forTimeInterval: 0.05)
        let second = finished("2.png", text: "two")
        store.save(second, isNewReading: true)
        XCTAssertEqual(history.search("").map(\.id), [second.id, first.id])

        let readAt = try XCTUnwrap(history.search("").last?.recognizedAt)
        var corrected = first
        corrected.ocrText = "one corrected"
        store.save(corrected)
        let after = history.search("").first { $0.id == first.id }
        XCTAssertEqual(after?.recognizedAt, readAt)
        XCTAssertEqual(history.text(for: first.id), "one corrected")
    }

    func testUnfinishedFilesAreNotRecorded() {
        var failed = ImageItem(url: URL(fileURLWithPath: "/x.png"))
        failed.status = .failed
        store.save(failed)
        XCTAssertTrue(history.search("").isEmpty)
    }

    func testRemovedFilesKeepTheirResultAndComeBack() throws {
        let item = finished("scan.png", text: "kept")
        store.save(item, isNewReading: true)
        store.saveQueue([item])
        store.remove([item.id])
        store.saveQueue([])

        XCTAssertTrue(store.load().isEmpty)
        XCTAssertEqual(history.search("kept").map(\.id), [item.id])
        XCTAssertEqual(store.historyPages(for: item.id)?.first?.rawText, "kept")

        store.restoreFromHistory(item.id)
        var back = item
        back.pages = []
        store.saveQueue([back])
        XCTAssertEqual(store.load().first?.pages.first?.rawText, "kept")
    }

    func testForgetAndClear() {
        let a = finished("a.png", text: "alpha")
        let b = finished("b.png", text: "beta")
        let c = finished("c.png", text: "gamma")
        for item in [a, b, c] { store.save(item, isNewReading: true) }
        store.remove([a.id])

        store.forget([a.id])
        XCTAssertNil(store.historyPages(for: a.id))
        XCTAssertEqual(Set(history.search("").map(\.id)), [b.id, c.id])

        // c is still in the list and stays.
        store.clearHistory(keeping: [c.id])
        XCTAssertEqual(history.search("").map(\.id), [c.id])
        XCTAssertEqual(history.recorded(among: [a.id, b.id, c.id]), [c.id])
    }
}
