import Foundation

/// The user's recorded macros, kept in the library folder.
@MainActor
@Observable
final class MacroLibrary {
    var macros: [Macro] {
        didSet { save() }
    }

    @ObservationIgnored private let file: URL

    init(directory: URL) {
        file = directory.appending(path: "Macros.json")
        macros = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Macro].self, from: $0) } ?? []
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

    private func save() {
        guard let data = try? JSONEncoder().encode(macros) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
