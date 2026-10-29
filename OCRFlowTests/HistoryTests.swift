import Foundation
import Testing
@testable import OCRFlow

final class HistoryTests {

    private let directory = URL.temporaryDirectory
        .appending(path: "HistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let store: ResultStore
    private var history: HistoryIndex { store.history }

    init() {
        store = ResultStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func finished(_ name: String, text: String) -> ImageItem {
        var item = ImageItem(url: URL(filePath: "/docs/\(name)"))
        item.status = .completed
        item.engine = .auto
        item.pages = [PageResult(size: CGSize(width: 10, height: 10), rawText: text)]
        item.ocrText = text
        return item
    }

    @Test func findsChineseAndEnglishPhrases() {
        let contract = finished("合同.pdf", text: "甲方应于二〇二四年三月一日前支付货款人民币壹万元整。")
        let paper = finished("paper.pdf", text: "Attention is all you need. The Transformer uses self-attention.")
        store.save(contract, isNewReading: true)
        store.save(paper, isNewReading: true)

        #expect(history.search("支付货款").map(\.id) == [contract.id])
        #expect(history.search("self-attention").map(\.id) == [paper.id])
        #expect(history.search("TRANSFORMER").map(\.id) == [paper.id])
        // A file is found by its name too.
        #expect(history.search("paper").map(\.id) == [paper.id])
        #expect(history.search("不存在的词").isEmpty)
        // A quote in the query is searched for, not parsed.
        #expect(history.search("\"货款").isEmpty)
    }

    @Test func shortQueriesStillMatch() {
        let contract = finished("合同.pdf", text: "甲方应支付货款。")
        store.save(contract, isNewReading: true)
        #expect(history.search("货款").map(\.id) == [contract.id])
        #expect(history.search("甲").map(\.id) == [contract.id])
        #expect(history.search("%").count == 0)
    }

    @Test func snippetMarksTheMatch() throws {
        let item = finished("a.txt", text: String(repeating: "前文", count: 50) + "关键内容" + String(repeating: "后文", count: 50))
        store.save(item, isNewReading: true)
        let (open, close) = HistoryIndex.snippetMarks
        for query in ["关键内容", "关键"] {
            let snippet = try #require(history.search(query).first?.snippet)
            #expect(snippet.contains(open + query + close), "\(snippet)")
            #expect(snippet.count < 200)
        }
    }

    @Test func newestFirstAndCorrectionsKeepTheDate() throws {
        let first = finished("1.png", text: "one")
        store.save(first, isNewReading: true)
        Thread.sleep(forTimeInterval: 0.05)
        let second = finished("2.png", text: "two")
        store.save(second, isNewReading: true)
        #expect(history.search("").map(\.id) == [second.id, first.id])

        let readAt = try #require(history.search("").last?.recognizedAt)
        var corrected = first
        corrected.ocrText = "one corrected"
        store.save(corrected)
        let after = history.search("").first { $0.id == first.id }
        #expect(after?.recognizedAt == readAt)
        #expect(history.text(for: first.id) == "one corrected")
    }

    @Test func unfinishedFilesAreNotRecorded() {
        var failed = ImageItem(url: URL(filePath: "/x.png"))
        failed.status = .failed
        store.save(failed)
        #expect(history.search("").isEmpty)
    }

    @Test func removedFilesKeepTheirResultAndComeBack() throws {
        let item = finished("scan.png", text: "kept")
        store.save(item, isNewReading: true)
        store.saveQueue([item])
        store.remove([item.id])
        store.saveQueue([])

        #expect(store.load().isEmpty)
        #expect(history.search("kept").map(\.id) == [item.id])
        #expect(store.historyPages(for: item.id)?.first?.rawText == "kept")

        store.restoreFromHistory(item.id)
        var back = item
        back.pages = []
        store.saveQueue([back])
        #expect(store.load().first?.pages.first?.rawText == "kept")
    }

    @Test func forgetAndClear() {
        let a = finished("a.png", text: "alpha")
        let b = finished("b.png", text: "beta")
        let c = finished("c.png", text: "gamma")
        for item in [a, b, c] { store.save(item, isNewReading: true) }
        store.remove([a.id])

        store.forget([a.id])
        #expect(store.historyPages(for: a.id) == nil)
        #expect(Set(history.search("").map(\.id)) == [b.id, c.id])

        // c is still in the list and stays.
        store.clearHistory(keeping: [c.id])
        #expect(history.search("").map(\.id) == [c.id])
        #expect(history.recorded(among: [a.id, b.id, c.id]) == [c.id])
    }
}
