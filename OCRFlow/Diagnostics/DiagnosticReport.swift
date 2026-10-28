import Foundation

/// What a person sends when something went wrong: the app, the Mac, the
/// settings, the models, and what failed — enough to reproduce a problem
/// without the files themselves.
///
/// Nothing a file says is included, and by default no file names either:
/// files are described by their type, size and page count. Folder paths are
/// never included.
struct DiagnosticReport {

    struct FileSummary {
        var name: String
        var fileExtension: String
        var bytes: Int64?
        var pages: Int
        var status: ProcessingStatus
        var engine: OCREngine?
        var error: String?
        /// Pages that failed inside a document that otherwise finished.
        var pageFailures: [String]
    }

    var appVersion: String
    var build: String
    var system: String
    var machine: String
    var memoryGB: Int
    var settings: OCRSettings
    var installedModels: [(name: String, bytes: Int64)]
    var files: [FileSummary]
    /// The crash log the last unexpected quit left, when there is one.
    var crashLog: String?

    /// The report as plain text, ready to paste into an issue or an email.
    func text(includingFileNames: Bool) -> String {
        var lines: [String] = []
        lines.append("OCRFlow \(appVersion) (\(build))")
        lines.append("macOS \(system) · \(machine) · \(memoryGB) GB")
        lines.append("")

        lines.append("## Settings")
        var settings = self.settings
        settings.watchFolderPath = settings.watchFolderPath.map { _ in "<set>" }
        settings.watchOutputPath = settings.watchOutputPath.map { _ in "<set>" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings), let json = String(data: data, encoding: .utf8) {
            lines.append(json)
        }
        lines.append("")

        lines.append("## Downloaded models")
        if installedModels.isEmpty { lines.append("(none)") }
        for model in installedModels {
            lines.append("- \(model.name) — \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))")
        }
        lines.append("")

        let counts = Dictionary(grouping: files, by: \.status).mapValues(\.count)
        lines.append("## Queue")
        lines.append([ProcessingStatus.pending, .processing, .completed, .failed, .cancelled]
            .map { "\($0.rawValue): \(counts[$0] ?? 0)" }
            .joined(separator: ", "))
        let troubled = files.enumerated().filter { $0.element.status == .failed || !$0.element.pageFailures.isEmpty }
        for (index, file) in troubled {
            let name = includingFileNames ? file.name : "file \(index + 1)"
            let size = file.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
            var line = "- \(name) (.\(file.fileExtension.lowercased()), \(size)"
            if file.pages > 1 { line += ", \(file.pages) pages" }
            line += ") — \(file.status.rawValue)"
            if let engine = file.engine { line += " with \(engine.rawValue)" }
            lines.append(line)
            if let error = file.error { lines.append("  \(error)") }
            for failure in file.pageFailures { lines.append("  \(failure)") }
        }
        lines.append("")

        if let crashLog {
            lines.append("## Crash log from the last unexpected quit")
            lines.append(crashLog)
        }
        return lines.joined(separator: "\n")
    }
}

extension DiagnosticReport {

    /// Where problems are reported.
    static let issuesURL = URL(string: "https://github.com/yb311/OCRFlow/issues/new")!

    static var currentSystem: (version: String, machine: String, memoryGB: Int) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let gigabytes = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return ("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                "\(String(cString: model)) \(arch)", gigabytes)
    }

    static func installedModels(in folder: URL) -> [(name: String, bytes: Int64)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { ["onnx", "gguf", "txt"].contains($0.pathExtension) }
            .map { ($0.lastPathComponent, Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)) }
            .sorted { $0.name < $1.name }
    }
}
