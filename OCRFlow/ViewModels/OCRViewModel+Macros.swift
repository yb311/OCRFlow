import AppKit
import ImageIO

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
            let recorded = await recording.run()
            activeRecording = nil
            isCapturing = false
            guard let recorded else { return }
            let steps = recorded.steps
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
            for (step, image) in recorded.captures { macros.keep(image, for: step) }
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
        let own = OwnWindows.tuck()
        Task {
            let player = MacroPlayer()
            // The run's captures keep the size of those taken while recording,
            // to be joined with them.
            var sizes: [UUID: CGSize] = [:]
            for step in macro.steps {
                guard let url = macros.recordedCapture(for: step.id),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
                sizes[step.id] = CGSize(width: width, height: height)
            }
            var runs = await player.run(macro, sizes: sizes)
            defer { try? FileManager.default.removeItem(at: player.folder) }
            isCapturing = false
            runningMacroID = nil
            own.restore()

            // What was captured while recording comes first: the run started
            // where the recording left off. Unless the run began by taking
            // the same again — on a page it opened afresh, say.
            var recorded = macros.recordedCaptures(of: macro)
            if !recorded.isEmpty {
                if let last = recorded.last, let first = runs.first?.first,
                   let a = PageImages.wholeImage(at: last).flatMap({ PageFingerprint($0) }),
                   let b = PageImages.wholeImage(at: first).flatMap({ PageFingerprint($0) }), a.isSamePage(as: b) {
                    recorded.removeLast()
                }
                if runs.isEmpty { runs = [recorded] } else { runs[0] = recorded + runs[0] }
            }

            let count = runs.reduce(0) { $0 + $1.count }
            guard count > 0 else {
                macros.discardRecordedCaptures(of: macro)
                return
            }
            // What becomes of them, asked now: it depends on what was taken.
            let choice = await ResultChoice.ask(String(localized: "“\(macro.name)” took \(count) screenshots"),
                                                options: [.recognize, .save, .discard])
            var folder: URL?
            if choice == .save {
                folder = ResultChoice.chooseFolder(String(localized: "Choose where to save the screenshots"))
                if folder == nil { return }
            }
            var files: [URL] = []
            if choice != .discard {
                for pages in runs where !pages.isEmpty {
                    files += await captureFiles(from: pages, as: macro.output, named: macro.name, into: folder)
                }
            }
            macros.discardRecordedCaptures(of: macro)
            if folder != nil {
                if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
            } else {
                deliver(files)
            }
        }
    }

    /// A step that captures what the user chooses, added to the end of a
    /// macro.
    func addCaptureStep(to id: UUID) {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            let chosen = await ScreenCapture.choose()
            isCapturing = false
            guard let chosen, let step = MacroRecording.captureStep(for: chosen.target),
                  let index = macros.macros.firstIndex(where: { $0.id == id }) else { return }
            macros.macros[index].steps.append(step)
        }
    }
}
