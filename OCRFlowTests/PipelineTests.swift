import Foundation
import Testing
import PDFKit
@testable import OCRFlow

final class PipelineTests {

    private let folder = URL.temporaryDirectory
        .appending(path: "PipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Document assembly

    private func block(_ label: PPLayoutLabel, _ text: String, order: Int) -> PPLayoutBlock {
        PPLayoutBlock(rect: CGRect(x: 0, y: CGFloat(order) * 40, width: 400, height: 30),
                      label: label, score: 0.9, readingOrder: order, text: text)
    }

    @Test func markdownDropsPageFurniture() {
        // Blocks arrive sorted into reading order by the layout stage.
        let blocks = [
            block(.docTitle, "年度报告", order: 0),
            block(.header, "内部资料", order: 1),
            block(.text, "第二段正文。", order: 2),
        ]
        let markdown = PPDocumentAssembler.markdown(from: blocks, dropping: [.header])
        #expect(markdown.hasPrefix("# 年度报告"), "\(markdown)")
        #expect(markdown.contains("第二段正文。"))
        #expect(!markdown.contains("内部资料"))
        #expect(PPDocumentAssembler.markdown(from: blocks).contains("内部资料"))
        #expect(!PPDocumentAssembler.plainText(from: blocks, dropping: [.header]).contains("#"))
    }

    // MARK: - Excel

    @Test func tableCellsKeepTheirSpans() throws {
        let html = "<table><tr><td rowspan=\"2\">项目</td><td colspan=\"2\">金额</td></tr><tr><td>上半年</td><td>下半年</td></tr></table>"
        let cells = try #require(TableWorkbook.cells(from: html))
        let item = try #require(cells.first { $0.text == "项目" })
        #expect(item.rowSpan == 2)
        let amount = try #require(cells.first { $0.text == "金额" })
        #expect(amount.columnSpan == 2)
        #expect(cells.first { $0.text == "下半年" }?.column == 2)
        #expect(TableWorkbook.cells(from: "just a line of text") == nil)
    }

    @Test func workbookIsAZipExcelCanRead() throws {
        let cells = try #require(TableWorkbook.cells(from: "<table><tr><td>A & B</td><td>1</td></tr></table>"))
        let url = folder.appending(path: "tables.xlsx")
        try TableWorkbook.write([.init(name: "Sheet/1", cells: cells), .init(name: "Sheet/1", cells: cells)], to: url)

        let listing = try run("/usr/bin/unzip", "-l", url.path(percentEncoded: false))
        for entry in ["[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
            #expect(listing.contains(entry), "\(listing)")
        }
        let sheet = try run("/usr/bin/unzip", "-p", url.path(percentEncoded: false), "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("A &amp; B"), "\(sheet)")
        // The test of the archive itself: unzip finds no errors.
        #expect(try run("/usr/bin/unzip", "-t", url.path(percentEncoded: false)).contains("No errors"))
    }

    // MARK: - Searchable PDF

    @Test func searchablePDFCarriesTheRecognisedText() throws {
        let size = CGSize(width: 400, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let source = folder.appending(path: "page.png")
        try #require(image.pngData).write(to: source)

        var item = ImageItem(url: source)
        item.status = .completed
        let quad = [CGPoint(x: 20, y: 20), CGPoint(x: 300, y: 20), CGPoint(x: 300, y: 50), CGPoint(x: 20, y: 50)]
        item.pages = [PageResult(size: size, lines: [PPTextLine(quad: quad, text: "Invoice 2025 发票",
                                                                confidence: 0.98, wasRotated: false)])]
        let output = folder.appending(path: "out.pdf")
        try SearchablePDFWriter.write([item], to: output)

        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount == 1)
        let text = pdf.page(at: 0)?.string ?? ""
        #expect(text.contains("Invoice"), "\(text)")
        #expect(text.contains("发票"), "\(text)")
    }

    // MARK: - Folder watching

    @Test(.timeLimit(.minutes(1)))
    @MainActor func watcherTakesSettledFilesOnceAndSkipsTheOutputFolder() async throws {
        let output = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "already.png"))

        let (handedOver, arrived) = AsyncStream.makeStream(of: [String].self)
        let watcher = FolderWatcher(folder: folder, excluding: output,
                                    shouldTake: { $0.lastPathComponent != "skip.png" },
                                    onFiles: { urls in arrived.yield(urls.map(\.lastPathComponent)) })
        watcher.start()
        try Data("y".utf8).write(to: folder.appending(path: "new.png"))
        try Data("z".utf8).write(to: folder.appending(path: "skip.png"))
        try Data("r".utf8).write(to: output.appending(path: "result.png"))
        try Data("t".utf8).write(to: folder.appending(path: "notes.txt"))

        var taken: [String] = []
        for await files in handedOver {
            taken += files
            if taken.contains("new.png") { break }
        }
        watcher.stop()

        #expect(Set(taken) == ["already.png", "new.png"])
        #expect(taken.count == 2, "each file is handed over once")
    }

    private func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
