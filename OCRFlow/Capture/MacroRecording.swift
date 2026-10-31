import AppKit
import SwiftUI

/// Recording a macro, as the user goes through it: a small panel says it is
/// recording; the user does what they want repeated, and captures what they
/// need — each capture a step — then clicks Done.
@MainActor
final class MacroRecording {
    private let recorder = MacroRecorder()
    private let state = MacroRecordState()
    private var panel: NSPanel?
    /// What each capture took while recording, in order.
    private var taken: [CGImage] = []

    struct Recorded {
        var steps: [MacroStep]
        /// What each capture step took while recording, by step.
        var captures: [UUID: CGImage]
    }

    /// The steps and what was captured, or nil when cancelled.
    func run() async -> Recorded? {
        guard InputControl.isAllowed(), ScreenCapture.checkAllowed() else { return nil }
        panel = HUDPanel.show(MacroRecordView(state: state), avoiding: ScreenWindows.frontWindow().map { window in
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(x: window.frame.minX, y: top - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        })
        recorder.onChange = { [state, recorder] in state.actions = recorder.actions }
        state.onCapture = { [weak self] in Task { await self?.captureHere() } }
        state.onLongCapture = { [weak self] in Task { await self?.captureHere(scrolling: true) } }
        recorder.start()
        let done = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var answered = false
            func answer(_ done: Bool) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: done)
            }
            state.onDone = { answer(true) }
            state.onCancel = { answer(false) }
        }
        state.onDone = {}
        state.onCancel = {}
        state.onCapture = {}
        state.onLongCapture = {}
        let steps = await recorder.stop()
        panel?.orderOut(nil)
        panel = nil
        guard done, !steps.isEmpty else { return nil }
        // Steps are made of what was recorded in order, every capture kept.
        let captureSteps = steps.filter { if case .capture = $0.action { true } else { false } }
        return Recorded(steps: steps,
                        captures: Dictionary(uniqueKeysWithValues: zip(captureSteps.map(\.id), taken)))
    }

    /// The user chooses an area or a window, and taking it becomes a step.
    /// `scrolling`: then scrolls on from there — by hand or automatically —
    /// to wherever they want it to end, and the step scrolls as far.
    func captureHere(scrolling: Bool = false) async {
        guard !state.isChoosing else { return }
        state.isChoosing = true
        defer { state.isChoosing = false }
        guard let chosen = await ScreenCapture.choose(),
              let step = Self.captureStep(for: chosen.target),
              case var .capture(area) = step.action else { return }
        var image = chosen.image
        if scrolling {
            recorder.isPaused = true
            defer { recorder.isPaused = false }
            let capture = ScrollingCapture()
            let (parts, finish) = await capture.run(chosen.target, first: chosen.image, finishes: [.cancel, .done])
            guard finish != .cancel, let long = parts.first else { return }
            image = long
            area.frameSize = CGSize(width: chosen.image.width, height: chosen.image.height)
            // How far it was scrolled, in points.
            if let frame = ScreenCapture.frame(of: chosen.target), frame.height > 0 {
                let pixelsPerPoint = CGFloat(chosen.image.height) / frame.height
                area.scrollDistance = Double(CGFloat(capture.grown) / pixelsPerPoint)
            }
        }
        recorder.addCapture(area, in: step.window)
        taken.append(image)
    }

    /// A step that takes the same again: the same window, or the same part
    /// of the window under it — wherever that window is by then.
    static func captureStep(for target: CaptureTarget) -> MacroStep? {
        switch target {
        case let .window(id):
            guard let window = ScreenWindows.all().first(where: { $0.id == id }) else { return nil }
            return MacroStep(action: .capture(CaptureArea(rect: nil)), window: window.place)
        case let .region(display, rect):
            let bounds = CGDisplayBounds(display)
            let onScreen = rect.offsetBy(dx: bounds.minX, dy: bounds.minY)
            guard let window = ScreenWindows.ordinary(at: CGPoint(x: onScreen.midX, y: onScreen.midY)) else {
                return MacroStep(action: .capture(CaptureArea(rect: onScreen)), window: nil)
            }
            return MacroStep(action: .capture(CaptureArea(rect: onScreen.offsetBy(dx: -window.frame.minX,
                                                                                  dy: -window.frame.minY))),
                             window: window.place)
        }
    }
}

// MARK: - What the panel shows

@MainActor
@Observable
final class MacroRecordState {
    /// Clicks, keys, scrolls and captures recorded so far.
    var actions = 0
    var isChoosing = false

    @ObservationIgnored var onDone: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onCapture: () -> Void = {}
    @ObservationIgnored var onLongCapture: () -> Void = {}
}

struct MacroRecordView: View {
    let state: MacroRecordState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Recording your actions")
            } icon: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
            .font(.headline)
            Text("Do what you want repeated, the way you normally would. To keep what is on screen at a point, click Capture Here — or use the screenshot shortcut. Long Screenshot Here scrolls on as far as you take it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(state.actions == 0 ? "Waiting for you…" : "Recorded: \(state.actions)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Button {
                    state.onCapture()
                } label: {
                    Label("Capture Here", systemImage: "viewfinder")
                }
                Button {
                    state.onLongCapture()
                } label: {
                    Label("Long Screenshot Here", systemImage: "arrow.up.and.down.square")
                }
            }
            .disabled(state.isChoosing)
            HStack {
                Spacer()
                Button("Cancel") { state.onCancel() }
                Button("Done") { state.onDone() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.actions == 0)
            }
        }
    }
}
