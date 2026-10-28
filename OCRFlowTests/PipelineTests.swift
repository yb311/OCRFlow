import XCTest
import PDFKit
@testable import OCRFlow

final class PipelineTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Document assembly

    private func block(_ label: PPLayoutLabel, _ text: String, order: Int) -> PPLayoutBlock {
        PPLayoutBlock(rect: CGRect(x: 0, y: CGFloat(order) * 40, width: 400, height: 30),
                      label: label, score: 0.9, readingOrder: order, text: text)
    }

    func testMarkdownDropsPageFurniture() {
        // Blocks arrive sorted into reading order by the layout stage.
        let blocks = [
            block(.docTitle, "年度报告", order: 0),
            block(.header, "内部资料", order: 1),
            block(.text, "第二段正文。", order: 2),
        ]
        let markdown = PPDocumentAssembler.markdown(from: blocks, dropping: [.header])
        XCTAssertTrue(markdown.hasPrefix("# 年度报告"), markdown)
        XCTAssertTrue(markdown.contains("第二段正文。"))
        XCTAssertFalse(markdown.contains("内部资料"))
        XCTAssertTrue(PPDocumentAssembler.markdown(from: blocks).contains("内部资料"))
        XCTAssertFalse(PPDocumentAssembler.plainText(from: blocks, dropping: [.header]).contains("#"))
    }

    // MARK: - Excel

    func testTableCellsKeepTheirSpans() throws {
        let html = "<table><tr><td rowspan=\"2\">项目</td><td colspan=\"2\">金额</td></tr><tr><td>上半年</td><td>下半年</td></tr></table>"
        let cells = try XCTUnwrap(TableWorkbook.cells(from: html))
        let item = try XCTUnwrap(cells.first { $0.text == "项目" })
        XCTAssertEqual(item.rowSpan, 2)
        let amount = try XCTUnwrap(cells.first { $0.text == "金额" })
        XCTAssertEqual(amount.columnSpan, 2)
        XCTAssertEqual(cells.first { $0.text == "下半年" }?.column, 2)
        XCTAssertNil(TableWorkbook.cells(from: "just a line of text"))
    }

    func testWorkbookIsAZipExcelCanRead() throws {
        let cells = try XCTUnwrap(TableWorkbook.cells(from: "<table><tr><td>A & B</td><td>1</td></tr></table>"))
        let url = folder.appendingPathComponent("tables.xlsx")
        try TableWorkbook.write([.init(name: "Sheet/1", cells: cells), .init(name: "Sheet/1", cells: cells)], to: url)

        let listing = try run("/usr/bin/unzip", "-l", url.path)
        for entry in ["[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
            XCTAssertTrue(listing.contains(entry), listing)
        }
        let sheet = try run("/usr/bin/unzip", "-p", url.path, "xl/worksheets/sheet1.xml")
        XCTAssertTrue(sheet.contains("A &amp; B"), sheet)
        // The test of the archive itself: unzip finds no errors.
        XCTAssertTrue(try run("/usr/bin/unzip", "-t", url.path).contains("No errors"))
    }

    // MARK: - Searchable PDF

    func testSearchablePDFCarriesTheRecognisedText() throws {
        let size = CGSize(width: 400, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let source = folder.appendingPathComponent("page.png")
        try XCTUnwrap(image.pngData).write(to: source)

        var item = ImageItem(url: source)
        item.status = .completed
        let quad = [CGPoint(x: 20, y: 20), CGPoint(x: 300, y: 20), CGPoint(x: 300, y: 50), CGPoint(x: 20, y: 50)]
        item.pages = [PageResult(size: size, lines: [PPTextLine(quad: quad, text: "Invoice 2025 发票",
                                                                confidence: 0.98, wasRotated: false)])]
        let output = folder.appendingPathComponent("out.pdf")
        try SearchablePDFWriter.write([item], to: output)

        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, 1)
        let text = pdf.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Invoice"), text)
        XCTAssertTrue(text.contains("发票"), text)
    }

    // MARK: - Folder watching

    @MainActor
    func testWatcherTakesSettledFilesOnceAndSkipsTheOutputFolder() throws {
        let output = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("already.png"))

        var taken: [String] = []
        let arrived = expectation(description: "files handed over")
        arrived.assertForOverFulfill = false
        let watcher = FolderWatcher(folder: folder, excluding: output,
                                    shouldTake: { $0.lastPathComponent != "skip.png" },
                                    onFiles: { urls in
                                        taken += urls.map(\.lastPathComponent)
                                        if taken.contains("new.png") { arrived.fulfill() }
                                    })
        watcher.start()
        try Data("y".utf8).write(to: folder.appendingPathComponent("new.png"))
        try Data("z".utf8).write(to: folder.appendingPathComponent("skip.png"))
        try Data("r".utf8).write(to: output.appendingPathComponent("result.png"))
        try Data("t".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        wait(for: [arrived], timeout: 15)
        watcher.stop()

        XCTAssertEqual(Set(taken), ["already.png", "new.png"])
        XCTAssertEqual(taken.count, 2, "each file is handed over once")
    }

    private func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
