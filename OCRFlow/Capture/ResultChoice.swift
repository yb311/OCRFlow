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
        /// Saved where the settings say, not read.
        case save
        case discard

        /// In OCRFlow's window, once read.
        var showsWhatWasRead: Bool {
            self == .recognize || self == .recognizeTogether || self == .recognizeEach
        }
    }

    /// `comesForward`: the choices after which OCRFlow is the app in front —
    /// by default those that show what was read in its window. It asks to
    /// come forward on the click itself: activation is cooperative, and an
    /// app the user has just clicked is let come forward, where one that
    /// asks later, from the background, may not be.
    static func ask(_ title: String, options: [Option],
                    comesForward: @escaping (Option) -> Bool = { $0.showsWhatWasRead }) async -> Option {
        // The panel is let go here, once answered, not from its own button:
        // held by what its view does, it would hold itself.
        var panel: NSPanel?
        let option = await withCheckedContinuation { continuation in
            var answered = false
            let view = ResultChoiceView(title: title, options: options) { option in
                guard !answered else { return }
                answered = true
                if comesForward(option) { NSApp.activate() }
                continuation.resume(returning: option)
            }
            panel = HUDPanel.show(view, avoiding: nil)
        }
        panel?.orderOut(nil)
        return option
    }
}

extension ResultChoice {
    /// Something gone wrong, said where the choice would have been asked,
    /// until the user has read it. Over whatever app is in front, without
    /// OCRFlow coming forward — an alert would, and its windows with it.
    ///
    /// `action`: a button beside OK that does something about it — Open
    /// System Settings, say.
    static func tell(_ title: String, _ message: String,
                     action: (label: String, perform: () -> Void)? = nil) async {
        // Let go here, once answered — see `ask`.
        var panel: NSPanel?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var answered = false
            @MainActor func answer(_ perform: () -> Void = {}) {
                guard !answered else { return }
                answered = true
                perform()
                continuation.resume()
            }
            let view = VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .symbolRenderingMode(.multicolor)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if let action {
                        Button("Cancel") { answer() }
                        Button(action.label) { answer(action.perform) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("OK") { answer() }
                    }
                }
            }
            panel = HUDPanel.show(view, avoiding: nil)
        }
        panel?.orderOut(nil)
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
        case .save: "Only save, without recognizing"
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
