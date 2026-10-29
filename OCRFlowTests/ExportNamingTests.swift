import XCTest
@testable import OCRFlow

final class ExportNamingTests: XCTestCase {

    private let output = URL(fileURLWithPath: "/tmp/out", isDirectory: true)

    func testResultKeepsTheSourceExtension() {
        let item = ImageItem(url: URL(fileURLWithPath: "/scans/scan.pdf"))
        let url = OCRViewModel.separateExportURLs(for: [item], format: .markdown, in: output)[0]
        XCTAssertEqual(url.path, "/tmp/out/scan.pdf_OCR.md")
    }

    func testSameStemDifferentExtensionNeverCollides() {
        let root = URL(fileURLWithPath: "/watched", isDirectory: true)
        let png = ImageItem(url: URL(fileURLWithPath: "/watched/a/scan.png"), root: root)
        let pdf = ImageItem(url: URL(fileURLWithPath: "/watched/a/scan.pdf"), root: root)

        // Exported one at a time, as a watched folder does, the two must still
        // land on different files.
        let first = OCRViewModel.separateExportURLs(for: [png], format: .plainText, in: output)[0]
        let second = OCRViewModel.separateExportURLs(for: [pdf], format: .plainText, in: output)[0]
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.path, "/tmp/out/watched/a/scan.png_OCR.txt")
        XCTAssertEqual(second.path, "/tmp/out/watched/a/scan.pdf_OCR.txt")
    }

    func testLooseFilesWithTheSameNameAreNumberedInOrder() {
        let a = ImageItem(url: URL(fileURLWithPath: "/one/page.png"))
        let b = ImageItem(url: URL(fileURLWithPath: "/two/page.png"))
        let c = ImageItem(url: URL(fileURLWithPath: "/three/page.png"))
        let urls = OCRViewModel.separateExportURLs(for: [a, b, c], format: .json, in: output)
        XCTAssertEqual(urls.map(\.lastPathComponent),
                       ["page.png_OCR.json", "page.png_OCR-2.json", "page.png_OCR-3.json"])
    }

    func testFolderStructureIsKeptBelowTheRoot() {
        let root = URL(fileURLWithPath: "/docs/合同", isDirectory: true)
        let item = ImageItem(url: URL(fileURLWithPath: "/docs/合同/2024/扫描001.pdf"), root: root)
        XCTAssertEqual(item.relativePath, "2024/扫描001.pdf")
        let url = OCRViewModel.separateExportURLs(for: [item], format: .markdown, in: output)[0]
        XCTAssertEqual(url.path, "/tmp/out/合同/2024/扫描001.pdf_OCR.md")
    }

    func testFileOutsideItsRootFallsBackToItsName() {
        let item = ImageItem(url: URL(fileURLWithPath: "/elsewhere/x.png"),
                             root: URL(fileURLWithPath: "/docs", isDirectory: true))
        XCTAssertEqual(item.relativePath, "x.png")
    }

    // MARK: - Translation

    func testOnlyParagraphsWithoutATranslationAreLeftToTranslate() {
        var item = ImageItem(url: URL(fileURLWithPath: "/a/doc.png"))
        item.ocrText = "First paragraph.\n\nSecond paragraph.\n\nFirst paragraph."
        item.translation = DocumentTranslation(target: "zh-Hans", paragraphs: ["First paragraph.": "第一段。"])

        XCTAssertEqual(DocumentTranslation.untranslated(in: item, target: "zh-Hans"), ["Second paragraph."])
        // Another language starts from nothing; a repeated paragraph is asked for once.
        XCTAssertEqual(DocumentTranslation.untranslated(in: item, target: "ja"),
                       ["First paragraph.", "Second paragraph."])
    }

    func testTranslatedDocumentFollowsTheCurrentText() {
        let translation = DocumentTranslation(target: "zh-Hans",
                                              paragraphs: ["One.": "一。", "Two.": "二。"])
        XCTAssertEqual(translation.document(of: "Two.\n\nOne.", bilingual: false), "二。\n\n一。")
        XCTAssertEqual(translation.document(of: "One.", bilingual: true), "One.\n\n一。")
    }
}
