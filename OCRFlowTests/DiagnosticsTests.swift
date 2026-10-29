import Foundation
import Testing
@testable import OCRFlow

struct DiagnosticsTests {

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

    @Test func fileNamesAndFolderPathsAreLeftOutByDefault() {
        let text = report(files: [failed]).text(includingFileNames: false)
        #expect(!text.contains("离婚协议"))
        #expect(!text.contains("Secret Folder"))
        #expect(!text.contains("/Users/someone"))
        #expect(text.contains("file 1 (.pdf"))
        #expect(text.contains("12 pages"))
        #expect(text.contains("The file couldn't be opened."))
        #expect(text.contains("PP-DocLayoutV3.onnx"))
        #expect(text.contains("failed: 1"))
    }

    @Test func fileNamesWhenAskedFor() {
        #expect(report(files: [failed]).text(includingFileNames: true).contains("离婚协议.pdf"))
    }

    @Test func finishedFilesAreCountedButNotListed() {
        var done = failed
        done.status = .completed
        done.error = nil
        let text = report(files: [done]).text(includingFileNames: true)
        #expect(text.contains("completed: 1"))
        #expect(!text.contains("离婚协议"))
    }

    @Test func sentinelFindsOnlyACrashAfterTheLastLaunch() throws {
        let folder = URL.temporaryDirectory
            .appending(path: "Sentinel-\(UUID().uuidString)", directoryHint: .isDirectory)
        let logs = folder.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sentinel = LaunchSentinel(directory: folder, crashLogFolder: logs)

        // A first launch, then a normal quit: nothing to report.
        #expect(sentinel.begin(processName: "OCRFlow") == nil)
        sentinel.end()
        #expect(sentinel.begin(processName: "OCRFlow") == nil)

        // An old crash log from before this launch does not count…
        let old = logs.appending(path: "OCRFlow-2020-01-01.ips")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)],
                                              ofItemAtPath: old.path(percentEncoded: false))
        // …nor one from another app.
        try Data("other".utf8).write(to: logs.appending(path: "Safari-now.ips"))
        // The session started above ends without `end()`, in a crash.
        let crash = logs.appending(path: "OCRFlow-now.ips")
        try Data("crash at \(URL.homeDirectory.appending(path: "x").path(percentEncoded: false))".utf8).write(to: crash)

        #expect(sentinel.begin(processName: "OCRFlow")?.lastPathComponent == crash.lastPathComponent)
        #expect(LaunchSentinel.excerpt(of: crash) == "crash at ~/x")
    }
}
