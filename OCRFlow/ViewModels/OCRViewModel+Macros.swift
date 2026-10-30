import AppKit

/// Recording what the user does, and doing it again.
extension OCRViewModel {
    /// Records what the user does until they click Done, then shows the new
    /// macro, ready to run.
    func recordMacro() {
        guard !isCapturing else { return }
        isCapturing = true
        let recording = MacroRecording()
        activeRecording = recording
        Task {
            let steps = await recording.run()
            activeRecording = nil
            isCapturing = false
            guard let steps else { return }
            let captures = steps.filter { if case .capture = $0.action { true } else { false } }.count
            let onlyScrolls = steps.allSatisfy { step in
                switch step.action {
                case .scroll, .capture, .wait: true
                default: false
                }
            }
            var macro = Macro(name: macros.newName(), steps: steps)
            // Capturing and moving on, page after page, until the end — the
            // usual reason to record; without a capture, done once.
            macro.repetition = captures > 0 ? .untilUnchanged : .once
            macro.output = captures > 0 && onlyScrolls ? .longImage : .document
            macros.macros.append(macro)
            selectedMacroID = macro.id
            showMacros?()
        }
    }

    /// Does a macro again, and reads what it captured.
    func runMacro(id: UUID) {
        guard !isCapturing, let macro = macros.macro(id), !macro.steps.isEmpty else { return }
        isCapturing = true
        runningMacroID = id
        // OCRFlow's own windows out of the way of the clicks.
        let shown = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        shown.forEach { $0.orderOut(nil) }
        Task {
            let runs = await MacroPlayer().run(macro)
            isCapturing = false
            runningMacroID = nil
            shown.forEach { $0.orderFront(nil) }
            var files: [URL] = []
            for images in runs where !images.isEmpty {
                files += await captureFiles(for: images, as: macro.output, named: macro.name)
            }
            guard !files.isEmpty else { return }
            showMainWindow?()
            addCaptures(files)
        }
    }

    /// A step that captures what the user chooses, added to the end of a
    /// macro.
    func addCaptureStep(to id: UUID) {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            let chosen = await ScreenCapture.choose(returnFocus: true)
            isCapturing = false
            guard let chosen, let step = MacroRecording.captureStep(for: chosen.target),
                  let index = macros.macros.firstIndex(where: { $0.id == id }) else { return }
            macros.macros[index].steps.append(step)
        }
    }
}
