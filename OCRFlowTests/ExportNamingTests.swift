import Foundation
import Testing
@testable import OCRFlow

struct ExportNamingTests {

    private let output = URL(filePath: "/tmp/out", directoryHint: .isDirectory)

    @Test func resultKeepsTheSourceExtension() {
        let item = ImageItem(url: URL(filePath: "/scans/scan.pdf"))
        let url = OCRViewModel.separateExportURLs(for: [item], format: .markdown, in: output)[0]
        #expect(url.path(percentEncoded: false) == "/tmp/out/scan.pdf_OCR.md")
    }

    @Test func sameStemDifferentExtensionNeverCollides() {
        let root = URL(filePath: "/watched", directoryHint: .isDirectory)
        let png = ImageItem(url: URL(filePath: "/watched/a/scan.png"), root: root)
        let pdf = ImageItem(url: URL(filePath: "/watched/a/scan.pdf"), root: root)

        // Exported one at a time, as a watched folder does, the two must still
        // land on different files.
        let first = OCRViewModel.separateExportURLs(for: [png], format: .plainText, in: output)[0]
        let second = OCRViewModel.separateExportURLs(for: [pdf], format: .plainText, in: output)[0]
        #expect(first != second)
        #expect(first.path(percentEncoded: false) == "/tmp/out/watched/a/scan.png_OCR.txt")
        #expect(second.path(percentEncoded: false) == "/tmp/out/watched/a/scan.pdf_OCR.txt")
    }

    @Test func looseFilesWithTheSameNameAreNumberedInOrder() {
        let a = ImageItem(url: URL(filePath: "/one/page.png"))
        let b = ImageItem(url: URL(filePath: "/two/page.png"))
        let c = ImageItem(url: URL(filePath: "/three/page.png"))
        let urls = OCRViewModel.separateExportURLs(for: [a, b, c], format: .json, in: output)
        #expect(urls.map(\.lastPathComponent) == ["page.png_OCR.json", "page.png_OCR-2.json", "page.png_OCR-3.json"])
    }

    @Test func folderStructureIsKeptBelowTheRoot() {
        let root = URL(filePath: "/docs/合同", directoryHint: .isDirectory)
        let item = ImageItem(url: URL(filePath: "/docs/合同/2024/扫描001.pdf"), root: root)
        #expect(item.relativePath == "2024/扫描001.pdf")
        let url = OCRViewModel.separateExportURLs(for: [item], format: .markdown, in: output)[0]
        #expect(url.path(percentEncoded: false) == "/tmp/out/合同/2024/扫描001.pdf_OCR.md")
    }

    @Test func fileOutsideItsRootFallsBackToItsName() {
        let item = ImageItem(url: URL(filePath: "/elsewhere/x.png"),
                             root: URL(filePath: "/docs", directoryHint: .isDirectory))
        #expect(item.relativePath == "x.png")
    }

    // MARK: - Translation

    @Test func onlyParagraphsWithoutATranslationAreLeftToTranslate() {
        var item = ImageItem(url: URL(filePath: "/a/doc.png"))
        item.ocrText = "First paragraph.\n\nSecond paragraph.\n\nFirst paragraph."
        item.translation = DocumentTranslation(target: "zh-Hans", paragraphs: ["First paragraph.": "第一段。"])

        #expect(DocumentTranslation.untranslated(in: item, target: "zh-Hans") == ["Second paragraph."])
        // Another language starts from nothing; a repeated paragraph is asked for once.
        #expect(DocumentTranslation.untranslated(in: item, target: "ja") == ["First paragraph.", "Second paragraph."])
    }

    @Test func targetIsTheLanguageMacOSOffers() {
        // As macOS 15 lists them.
        let supported = ["ar-AE", "de", "en", "en-GB", "es", "fr", "ja", "zh", "zh-TW"]
        #expect(DocumentTranslation.target("zh", among: supported) == "zh")
        #expect(DocumentTranslation.target("zh-Hans", among: supported) == "zh")
        #expect(DocumentTranslation.target("zh-US", among: supported) == "zh")
        #expect(DocumentTranslation.target("zh-HK", among: supported) == "zh-TW")
        #expect(DocumentTranslation.target("en-GB", among: supported) == "en-GB")
        #expect(DocumentTranslation.target("en-CN", among: supported) == "en")
        #expect(DocumentTranslation.target("ar", among: supported) == "ar-AE")
        #expect(DocumentTranslation.target("de-AT", among: supported) == "de")
        #expect(DocumentTranslation.target("sw", among: supported) == nil)
    }

    @Test func translatedDocumentFollowsTheCurrentText() {
        let translation = DocumentTranslation(target: "zh-Hans",
                                              paragraphs: ["One.": "一。", "Two.": "二。"])
        #expect(translation.document(of: "Two.\n\nOne.", bilingual: false) == "二。\n\n一。")
        #expect(translation.document(of: "One.", bilingual: true) == "One.\n\n一。")
    }
}
