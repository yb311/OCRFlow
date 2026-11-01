import SwiftUI

/// The user's recorded macros: what each does, step by step, how often, and
/// what becomes of what it captures.
struct MacroEditorView: View {
    static let windowID = "macros"
    @Environment(OCRViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        @Bindable var library = vm.macros
        NavigationSplitView {
            List(selection: $vm.selectedMacroID) {
                ForEach(library.macros) { macro in
                    Label(macro.name, systemImage: macro.id == vm.runningMacroID ? "play.circle.fill" : "record.circle")
                        .tag(macro.id)
                        .contextMenu {
                            Button("Run") { vm.runMacro(id: macro.id) }
                                .disabled(vm.isCapturing)
                            Divider()
                            Button("Delete", role: .destructive) { delete(macro.id) }
                        }
                }
                .onDelete { offsets in
                    for index in offsets { delete(library.macros[index].id) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .toolbar {
                ToolbarItem {
                    Button {
                        vm.recordMacro()
                    } label: {
                        Label("Record Actions…", systemImage: "record.circle")
                    }
                    .disabled(vm.isCapturing)
                    .help("Record Actions…")
                }
            }
        } detail: {
            if let index = library.macros.firstIndex(where: { $0.id == vm.selectedMacroID }) {
                MacroDetailView(macro: $library.macros[index])
            } else {
                ContentUnavailableView {
                    Label("No Recorded Actions Selected", systemImage: "record.circle")
                } description: {
                    Text("Do something once while OCRFlow watches — turn the pages of a slideshow, scroll a page, click through a list — and it can do it again, capturing as it goes.")
                } actions: {
                    Button("Record Actions…") { vm.recordMacro() }
                        .disabled(vm.isCapturing)
                }
            }
        }
    }

    private func delete(_ id: UUID) {
        vm.macros.macros.removeAll { $0.id == id }
        if vm.selectedMacroID == id { vm.selectedMacroID = nil }
    }
}

private struct MacroDetailView: View {
    @Binding var macro: Macro
    @Environment(OCRViewModel.self) private var vm

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $macro.name)
            }

            Section {
                if macro.steps.isEmpty {
                    Text("No steps.").foregroundStyle(.secondary)
                }
                ForEach($macro.steps) { $step in
                    MacroStepRow(step: $step, number: (macro.steps.firstIndex { $0.id == step.id } ?? 0) + 1,
                                 recorded: vm.macros.recordedCapture(for: step.id))
                        .contextMenu {
                            Button("Move Up") { move(step.id, by: -1) }
                                .disabled(macro.steps.first?.id == step.id)
                            Button("Move Down") { move(step.id, by: 1) }
                                .disabled(macro.steps.last?.id == step.id)
                            Divider()
                            Button("Delete Step", role: .destructive) { macro.steps.removeAll { $0.id == step.id } }
                        }
                }
            } header: {
                HStack {
                    Text("Steps")
                    Spacer()
                    Menu("Add Step") {
                        Button("Wait") { macro.steps.append(MacroStep(action: .wait(seconds: 1))) }
                        Button("Capture…") { vm.addCaptureStep(to: macro.id) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } footer: {
                Text("Steps run one after another, each once the screen has settled. Right-click a step to move or delete it.")
                    .foregroundStyle(.secondary)
            }

            Section("Repeat") {
                Picker("How often", selection: repetitionKind) {
                    Text("Once").tag(RepetitionKind.once)
                    Text("A number of times").tag(RepetitionKind.times)
                    Text("Until the screen stops changing").tag(RepetitionKind.untilUnchanged)
                }
                if case let .times(count) = macro.repetition {
                    Stepper(value: Binding(get: { count }, set: { macro.repetition = .times($0) }), in: 1...MacroPlayer.roundLimit) {
                        Text("\(count) times")
                    }
                }
            }

            Section {
                // A text editor, not a field: Return starts the next address
                // rather than ending the editing.
                TextEditor(text: urls)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72, maxHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if macro.urls.allSatisfy({ $0.isEmpty }) {
                            Text(verbatim: "https://example.com/first\nhttps://example.com/second")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(Text("Addresses"))
            } header: {
                Text("Pages to Open")
            } footer: {
                Text("One address a line. Each is opened in turn and the steps are done on it. Leave empty to work wherever things are.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Captures become", selection: $macro.output) {
                    Text("One document").tag(Macro.Output.document)
                    Text("One long picture").tag(Macro.Output.longImage)
                    Text("Separate pictures").tag(Macro.Output.images)
                }
            } header: {
                Text("Result")
            } footer: {
                Text("When a run ends, you choose whether they are recognized, only saved, or discarded.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(macro.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.runMacro(id: macro.id)
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(vm.isCapturing || macro.steps.isEmpty)
                .help("Run")
            }
        }
    }

    private enum RepetitionKind: Hashable { case once, times, untilUnchanged }

    private var repetitionKind: Binding<RepetitionKind> {
        Binding {
            switch macro.repetition {
            case .once: .once
            case .times: .times
            case .untilUnchanged: .untilUnchanged
            }
        } set: { kind in
            switch kind {
            case .once: macro.repetition = .once
            case .times: macro.repetition = .times(10)
            case .untilUnchanged: macro.repetition = .untilUnchanged
            }
        }
    }

    private var urls: Binding<String> {
        Binding { macro.urls.joined(separator: "\n") } set: { macro.urls = $0.components(separatedBy: .newlines) }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = macro.steps.firstIndex(where: { $0.id == id }),
              macro.steps.indices.contains(index + offset) else { return }
        macro.steps.swapAt(index, index + offset)
    }
}

private struct MacroStepRow: View {
    @Binding var step: MacroStep
    let number: Int
    /// What a capture step took while it was recorded, still to be handed on.
    let recorded: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 18, alignment: .trailing)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(MacroStepDescription.title(of: step))
                if let place = MacroStepDescription.place(of: step) {
                    Text(place).font(.caption).foregroundStyle(.secondary)
                }
                if let recorded, let preview = PageImages.thumbnail(of: recorded, maxPixels: 240) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(decorative: preview, scale: 2)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                        Text("Captured while recording. It comes first in the next run; deleting this step deletes it too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                editor
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch step.action {
        case let .click(click) where click.element?.name != nil:
            Picker("Aim at", selection: Binding(get: { click.findsElement }, set: { finds in
                var click = click
                click.findsElement = finds
                step.action = .click(click)
            })) {
                Text("The control, wherever it is").tag(true)
                Text("The same place in the window").tag(false)
            }
            .pickerStyle(.radioGroup)
            .font(.caption)
        case let .type(typed):
            TextField("Text", text: Binding(get: { typed.text }, set: {
                // Edited, the text no longer matches the keys pressed.
                step.action = .type(MacroStep.TypedText(text: $0))
            }))
        case let .wait(seconds):
            // The title says how long already.
            Stepper("Wait", value: Binding(get: { seconds }, set: { step.action = .wait(seconds: $0) }), in: 0.5...60, step: 0.5)
                .labelsHidden()
        default:
            EmptyView()
        }
    }

    private var icon: String {
        switch step.action {
        case .click: "cursorarrow.click"
        case .drag: "hand.draw"
        case .key: "keyboard"
        case .type: "character.cursor.ibeam"
        case .scroll: "arrow.up.and.down"
        case .capture: "viewfinder"
        case .wait: "hourglass"
        }
    }
}

/// What a step does, in words.
enum MacroStepDescription {
    static func title(of step: MacroStep) -> String {
        switch step.action {
        case let .click(click):
            let kind = switch (click.button, click.count) {
            case (.right, _): String(localized: "Right-click")
            case (_, 2...): String(localized: "Double-click")
            default: String(localized: "Click")
            }
            let keys = modifierSymbols(click.modifiers)
            if let name = click.element?.name {
                return String(localized: "\(keys)\(kind) “\(name)”")
            }
            return String(localized: "\(keys)\(kind) at \(String(Int(click.point.x))), \(String(Int(click.point.y)))",
                      comment: "A click by position in its window: modifier keys, the kind of click, x, y")
        case .drag:
            return String(localized: "Drag")
        case let .key(key):
            return String(localized: "Press \(keyName(key))")
        case let .type(typed):
            return String(localized: "Type “\(typed.text)”")
        case let .scroll(scroll):
            if abs(scroll.dy) >= abs(scroll.dx) {
                return scroll.dy < 0 ? String(localized: "Scroll down \(Int(-scroll.dy)) pt")
                    : String(localized: "Scroll up \(Int(scroll.dy)) pt")
            }
            return scroll.dx < 0 ? String(localized: "Scroll right \(Int(-scroll.dx)) pt")
                : String(localized: "Scroll left \(Int(scroll.dx)) pt")
        case let .capture(area):
            // Sizes and positions as plain numbers: 1120, not 1,120.
            let what = area.rect.map { String(localized: "Capture an area of \(String(Int($0.width))) × \(String(Int($0.height)))") }
                ?? String(localized: "Capture the window")
            guard let distance = area.scrollDistance else { return what }
            return String(localized: "\(what), scrolled on \(String(Int(distance))) pt into one long picture")
        case let .wait(seconds):
            return String(localized: "Wait \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s")
        }
    }

    /// Where: the app, and the window's title when it has one.
    static func place(of step: MacroStep) -> String? {
        guard let window = step.window else {
            if case .capture = step.action { return String(localized: "On the screen") }
            return nil
        }
        guard let title = window.title, !title.isEmpty else { return window.appName }
        return "\(window.appName) — \(title)"
    }

    static func keyName(_ key: MacroStep.Key) -> String {
        let names: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: String(localized: "Space"), 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 116: "⇞", 121: "⇟", 115: "↖", 119: "↘",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return modifierSymbols(key.modifiers) + (names[key.keyCode] ?? key.characters.uppercased())
    }

    private static func modifierSymbols(_ raw: UInt64) -> String {
        let flags = CGEventFlags(rawValue: raw)
        var symbols = ""
        if flags.contains(.maskControl) { symbols += "⌃" }
        if flags.contains(.maskAlternate) { symbols += "⌥" }
        if flags.contains(.maskShift) { symbols += "⇧" }
        if flags.contains(.maskCommand) { symbols += "⌘" }
        return symbols
    }
}
