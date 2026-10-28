import XCTest
import AppKit
@testable import OCRFlow

/// Runs the bundled PP-OCRv6 models on a real rendered page: no mocks.
final class OrientationTests: XCTestCase {

    /// A two-column page: the left column says 甲, the right one 乙, so the
    /// reading order can be read off the text.
    private func twoColumnPage() -> CGImage {
        let size = NSSize(width: 1200, height: 900)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let font = NSFont(name: "Songti SC", size: 34) ?? .systemFont(ofSize: 34)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            for row in 0..<6 {
                let y = 120 + CGFloat(row) * 110
                ("甲栏第\(row + 1)行文字内容" as NSString).draw(at: NSPoint(x: 60, y: y), withAttributes: attributes)
                ("乙栏第\(row + 1)行文字内容" as NSString).draw(at: NSPoint(x: 660, y: y), withAttributes: attributes)
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private func rotated90(_ image: CGImage) -> CGImage {
        let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }

    private func read(_ image: CGImage, orientation: Bool) throws -> String {
        var config = PPOCRConfig.default
        config.readingOrder = .columns
        config.useDocOrientation = orientation
        let engine = try PPOCREngine(config: config)
        return try engine.recognize(image: image).lines.map(\.text).joined(separator: "\n")
    }

    /// Every 甲 line before every 乙 line.
    private func assertColumnsInOrder(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lines = text.split(separator: "\n")
        let left = lines.indices.filter { lines[$0].hasPrefix("甲") }
        let right = lines.indices.filter { lines[$0].hasPrefix("乙") }
        XCTAssertEqual(left.count, 6, text, file: file, line: line)
        XCTAssertEqual(right.count, 6, text, file: file, line: line)
        XCTAssertLessThan(left.max() ?? .max, right.min() ?? .min, text, file: file, line: line)
    }

    func testUprightTwoColumnPageReadsLeftColumnFirst() throws {
        assertColumnsInOrder(try read(twoColumnPage(), orientation: true))
    }

    func testSidewaysPageIsStraightenedAndReadInColumnOrder() throws {
        let sideways = rotated90(twoColumnPage())
        assertColumnsInOrder(try read(sideways, orientation: true))
    }

    func testBoxesComeBackInTheSidewaysImagesCoordinates() throws {
        let sideways = rotated90(twoColumnPage())
        var config = PPOCRConfig.default
        config.useDocOrientation = true
        let lines = try PPOCREngine(config: config).recognize(image: sideways).lines
        let bounds = CGRect(x: 0, y: 0, width: sideways.width, height: sideways.height).insetBy(dx: -2, dy: -2)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertTrue(bounds.contains(line.boundingBox), "\(line.boundingBox) outside \(bounds)")
            // A line of text on a page turned sideways runs down the image.
            XCTAssertGreaterThan(line.boundingBox.height, line.boundingBox.width, line.text)
        }
    }
}
