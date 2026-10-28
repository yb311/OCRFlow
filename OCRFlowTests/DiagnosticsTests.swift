import XCTest
@testable import OCRFlow

final class DiagnosticsTests: XCTestCase {

    private func report(files: [DiagnosticReport.FileSummary], crashLog: String? = nil) -> DiagnosticReport {
        var settings = OCRSettings()
        settings.watchFolderPath = "/Users/someone/Secret Folder"
        settings.watchOutputPath = "/Users/someone/Out"
        return DiagnosticReport(appVersion: "1.2", build: "34", system: "15.1", machine: "Mac15,3 arm64",
                                memoryGB: 16, settings: settings,
                                installedModels: [("PP-DocLayoutV3.onnx", 130_000_000)],
                                files: files, crashLog: crashLog)
    }

    private let failed = DiagnosticReport.FileSummary(
        name: "离婚协议.pdf", fileExtension: "PDF", bytes: 2_000_000, pages: 12,
        status: .failed, engine: .auto, error: "The file couldn't be opened.", pageFailures: [])

    func testFileNamesAndFolderPathsAreLeftOutByDefault() {
        let text = report(files: [failed]).text(includingFileNames: false)
        XCTAssertFalse(text.contains("离婚协议"))
        XCTAssertFalse(text.contains("Secret Folder"))
        XCTAssertFalse(text.contains("/Users/someone"))
        XCTAssertTrue(text.contains("file 1 (.pdf"))
        XCTAssertTrue(text.contains("12 pages"))
        XCTAssertTrue(text.contains("The file couldn't be opened."))
        XCTAssertTrue(text.contains("PP-DocLayoutV3.onnx"))
        XCTAssertTrue(text.contains("failed: 1"))
    }

    func testFileNamesWhenAskedFor() {
        XCTAssertTrue(report(files: [failed]).text(includingFileNames: true).contains("离婚协议.pdf"))
    }

    func testFinishedFilesAreCountedButNotListed() {
        var done = failed
        done.status = .completed
        done.error = nil
        let text = report(files: [done]).text(includingFileNames: true)
        XCTAssertTrue(text.contains("completed: 1"))
        XCTAssertFalse(text.contains("离婚协议"))
    }

    func testSentinelFindsOnlyACrashAfterTheLastLaunch() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sentinel-\(UUID().uuidString)", isDirectory: true)
        let logs = folder.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sentinel = LaunchSentinel(directory: folder, crashLogFolder: logs)

        // A first launch, then a normal quit: nothing to report.
        XCTAssertNil(sentinel.begin(processName: "OCRFlow"))
        sentinel.end()
        XCTAssertNil(sentinel.begin(processName: "OCRFlow"))

        // An old crash log from before this launch does not count…
        let old = logs.appendingPathComponent("OCRFlow-2020-01-01.ips")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)],
                                              ofItemAtPath: old.path)
        // …nor one from another app.
        try Data("other".utf8).write(to: logs.appendingPathComponent("Safari-now.ips"))
        // The session started above ends without `end()`, in a crash.
        let crash = logs.appendingPathComponent("OCRFlow-now.ips")
        try Data("crash at \(FileManager.default.homeDirectoryForCurrentUser.path)/x".utf8).write(to: crash)

        XCTAssertEqual(sentinel.begin(processName: "OCRFlow")?.lastPathComponent, crash.lastPathComponent)
        XCTAssertEqual(LaunchSentinel.excerpt(of: crash), "crash at ~/x")
    }
}
