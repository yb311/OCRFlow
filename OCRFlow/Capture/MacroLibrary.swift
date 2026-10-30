import CoreGraphics
import Foundation

/// The user's recorded macros, kept in the library folder.
///
/// What a capture step took while it was recorded is kept beside it, to
/// come first in the next run: the user captured it, and the run starts
/// where the recording left off. It goes with its step.
@MainActor
@Observable
final class MacroLibrary {
    var macros: [Macro] {
        didSet { save() }
    }

    /// Counts changes to the captures kept, which live in files: views that
    /// show them read it to know when to look again.
    private var capturesChanged = 0

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let capturesFolder: URL

    init(directory: URL) {
        file = directory.appending(path: "Macros.json")
        capturesFolder = directory.appending(path: "Macro Captures", directoryHint: .isDirectory)
        macros = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Macro].self, from: $0) } ?? []
        removeUnusedCaptures()
    }

    func macro(_ id: UUID?) -> Macro? {
        macros.first { $0.id == id }
    }

    /// A name not taken yet: 「录制 1」, 「录制 2」…
    func newName() -> String {
        var number = 1
        while macros.contains(where: { $0.name == String(localized: "Recording \(number)") }) { number += 1 }
        return String(localized: "Recording \(number)")
    }

    // MARK: - Captures taken while recording

    /// Keeps what a capture step took while it was recorded.
    func keep(_ image: CGImage, for step: UUID) {
        try? FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        _ = PageByPageCapture.write(image, to: captureFile(for: step))
        capturesChanged += 1
    }

    /// What the step took while recorded, if it is still waiting for a run.
    func recordedCapture(for step: UUID) -> URL? {
        _ = capturesChanged
        let url = captureFile(for: step)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Those of a macro's, in step order.
    func recordedCaptures(of macro: Macro) -> [URL] {
        macro.steps.compactMap { recordedCapture(for: $0.id) }
    }

    /// Once a run has taken them in.
    func discardRecordedCaptures(of macro: Macro) {
        for url in recordedCaptures(of: macro) { try? FileManager.default.removeItem(at: url) }
        capturesChanged += 1
    }

    private func captureFile(for step: UUID) -> URL {
        capturesFolder.appending(path: "\(step.uuidString).png")
    }

    /// A capture whose step, or whole macro, was deleted goes too.
    private func removeUnusedCaptures() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: capturesFolder, includingPropertiesForKeys: nil)
        else { return }
        let steps = Set(macros.flatMap(\.steps).map(\.id.uuidString))
        for file in files where !steps.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func save() {
        removeUnusedCaptures()
        guard let data = try? JSONEncoder().encode(macros) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
