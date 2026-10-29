import XCTest
@testable import OCRFlow

final class CaptureTests: XCTestCase {

    /// A selection on a Retina display to the left of and above the main
    /// one: screen coordinates grow upward from the main display's corner,
    /// pictures downward from their own display's.
    func testSelectionIsMeasuredFromItsOwnDisplaysTopLeft() {
        let display = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        let selection = CGRect(x: -1820, y: 1000, width: 200, height: 100)
        let (points, pixels) = CaptureOverlay.place(selection, on: display, pixelWidth: 3840)
        XCTAssertEqual(points, CGRect(x: 100, y: 962, width: 200, height: 100))
        XCTAssertEqual(pixels, CGRect(x: 200, y: 1924, width: 400, height: 200))
    }

    func testWholeDisplayIsTheWholePicture() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let (points, pixels) = CaptureOverlay.place(display, on: display, pixelWidth: 3024)
        XCTAssertEqual(points, CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 3024, height: 1964))
    }

    /// A selection on half points still cuts whole pixels, and never less
    /// than was selected.
    func testHalfPointsRoundOutward() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let selection = CGRect(x: 10.25, y: 20.25, width: 30.5, height: 40.5)
        let (_, pixels) = CaptureOverlay.place(selection, on: display, pixelWidth: 1000)
        XCTAssertEqual(pixels, CGRect(x: 10, y: 939, width: 31, height: 41))
    }
}
