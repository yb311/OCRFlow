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
            for (step, capture) in recorded.captures {
                macros.keep(capture.image, for: step, pixelsPerPoint: capture.pixelsPerPoint)
            }
            selectedMacroID = macro.id
            showMacros?()
        }
    }

    /// Does a macro again, and reads what it captured.
    func runMacro(id: UUID) {
        guard !isCapturing, let macro = macros.macro(id), !macro.steps.isEmpty else { return }
        isCapturing = true
        runningMacroID = id
        // OCRFlow's own windows out of the way: the screen as it was when
        // the steps were recorded — see `OwnWindows`.
        let own = OwnWindows.tuck()
        Task {
            let player = MacroPlayer()
            var runs = await player.run(macro)
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
                   let a = PageImages.wholeImage(at: last), let b = PageImages.wholeImage(at: first),
                   Self.isSamePicture(a, b) {
                    recorded.removeLast()
                }
                if runs.isEmpty { runs = [recorded] } else { runs[0] = recorded + runs[0] }
            }

            let count = runs.reduce(0) { $0 + $1.count }
            guard count > 0 else {
                macros.discardRecordedCaptures(of: macro)
                // Said, rather than nothing at all happening.
                let captures = macro.steps.contains { if case .capture = $0.action { true } else { false } }
                if captures, !player.wasStopped { Self.reportNothingCaptured(macro.name, missingApp: player.missingApp) }
                return
            }
            // What becomes of them, asked now: it depends on what was taken.
            // Run from OCRFlow's own window, OCRFlow comes back to the front
            // whatever the choice.
            let title = player.wasStopped ? String(localized: "“\(macro.name)” was stopped. Screenshots taken: \(count)")
                : String(localized: "“\(macro.name)” is done. Screenshots taken: \(count)")
            let choice = await ResultChoice.ask(title, options: [.recognize, .save, .discard],
                                                comesForward: { own.wasInFront || $0.showsWhatWasRead })
            let folder = choice == .save ? screenshotDestination : nil
            var files: [URL] = []
            if choice != .discard {
                for pages in runs where !pages.isEmpty {
                    files += await captureFiles(from: pages, as: macro.output, named: macro.name, into: folder)
                }
            }
            macros.discardRecordedCaptures(of: macro)
            if let folder {
                reportSaved(files, in: folder)
            } else {
                deliver(files)
            }
        }
    }

    /// Why a run took nothing, as far as is known.
    /// In a panel over every app, as the choice would have been: an alert
    /// would need OCRFlow in front, which another app may now be.
    private static func reportNothingCaptured(_ name: String, missingApp: String?) {
        let message = missingApp.map {
            String(localized: "No window of “\($0)” is open. Open the window the actions were recorded in, then run them again.")
        } ?? String(localized: "Check that the window the actions were recorded in is open and not covered, then run them again.")
        Task { await ResultChoice.tell(String(localized: "“\(name)” took no screenshots"), message) }
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

    /// The same picture, give or take how far a long one reaches: their
    /// tops are compared, a screenful no taller than they are wide, strictly
    /// — two slides of one deck differ by a word.
    nonisolated static func isSamePicture(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width else { return false }
        let height = min(a.height, b.height, a.width)
        func top(_ image: CGImage) -> PageFingerprint? {
            image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: height)).flatMap { PageFingerprint($0) }
        }
        guard let x = top(a), let y = top(b) else { return false }
        return x.isSamePage(as: y)
    }
}
