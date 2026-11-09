import CoreGraphics
import Foundation
import os

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
    /// Some of the macros could not be read: the captures of those are kept
    /// too, with the file set aside, rather than cleared away as unused.
    @ObservationIgnored private var keepsUnusedCaptures = false

    private static let log = Logger(subsystem: "com.ocrflow.app", category: "macros")

    init(directory: URL) {
        file = directory.appending(path: "Macros.json")
        capturesFolder = directory.appending(path: "Macro Captures", directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: file) else {
            macros = []
            removeUnusedCaptures()
            return
        }
        // One by one: a macro that cannot be read loses only itself.
        let read = try? JSONDecoder().decode([Readable].self, from: data)
        macros = read?.compactMap(\.macro) ?? []
        if read == nil || read?.contains(where: { $0.macro == nil }) == true {
            // Set aside as it was, not written over by the next save.
            let aside = directory.appending(path: "Macros.json.unreadable-\(Date().ISO8601Format())")
            do {
                if read == nil {
                    try FileManager.default.moveItem(at: file, to: aside)
                } else {
                    try FileManager.default.copyItem(at: file, to: aside)
                }
                Self.log.error("Macros.json could not be read in full; set aside as \(aside.lastPathComponent, privacy: .public)")
            } catch {
                Self.log.error("Macros.json could not be read in full, nor set aside: \(error, privacy: .public)")
            }
            keepsUnusedCaptures = true
        } else {
            removeUnusedCaptures()
        }
    }

    /// A macro if it can be read; nil, rather than an error, if not.
    private struct Readable: Decodable {
        let macro: Macro?
        init(from decoder: any Decoder) throws {
            macro = try? Macro(from: decoder)
        }
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
    func keep(_ image: CGImage, for step: UUID, pixelsPerPoint: CGFloat) {
        try? FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        _ = ScreenshotFormat.png.write(image, to: captureFile(for: step), pixelsPerPoint: pixelsPerPoint)
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
        guard !keepsUnusedCaptures,
              let files = try? FileManager.default.contentsOfDirectory(at: capturesFolder, includingPropertiesForKeys: nil)
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
