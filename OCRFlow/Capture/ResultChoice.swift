import AppKit
import SwiftUI

/// Asked when several captures are done — a queue of screenshots ended, a
/// macro has run: what becomes of them. Asked there and then, rather than
/// settled once in the settings, since it depends on what was just taken.
@MainActor
enum ResultChoice {
    enum Option: Hashable, Sendable {
        /// One document, a page each, read together.
        case recognizeTogether
        /// Each read on its own.
        case recognizeEach
        /// Read, as the macro puts them together.
        case recognize
        /// Saved where the user picks, not read.
        case save
        case discard
    }

    static func ask(_ title: String, options: [Option]) async -> Option {
        await withCheckedContinuation { continuation in
            var panel: NSPanel?
            var answered = false
            let view = ResultChoiceView(title: title, options: options) { option in
                guard !answered else { return }
                answered = true
                panel?.orderOut(nil)
                continuation.resume(returning: option)
            }
            panel = HUDPanel.show(view, avoiding: nil)
        }
    }

    /// A folder for saving into, chosen now. Nil when cancelled.
    static func chooseFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = String(localized: "Save Here")
        return OwnWindows.whileModal { panel.runModal() } == .OK ? panel.url : nil
    }
}

private struct ResultChoiceView: View {
    let title: String
    let options: [ResultChoice.Option]
    let pick: (ResultChoice.Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button { pick(option) } label: {
                        Label(label(option), systemImage: symbol(option))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(option == options.first ? .accentColor : nil)
                }
            }
        }
    }

    private func label(_ option: ResultChoice.Option) -> LocalizedStringKey {
        switch option {
        case .recognizeTogether: "Recognize as one document"
        case .recognizeEach: "Recognize each on its own"
        case .recognize: "Recognize the text"
        case .save: "Only save the pictures…"
        case .discard: "Discard"
        }
    }

    private func symbol(_ option: ResultChoice.Option) -> String {
        switch option {
        case .recognizeTogether: "doc.text.viewfinder"
        case .recognizeEach: "square.stack"
        case .recognize: "text.viewfinder"
        case .save: "square.and.arrow.down"
        case .discard: "trash"
        }
    }
}
