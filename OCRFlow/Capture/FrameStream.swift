import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

/// The frames of a place on screen as they change — the way a recording
/// sees it — rather than one picture at a time: cheap enough to keep up with
/// a view being scrolled.
///
/// Frames arrive on a queue of its own and go to `onFrame` there, one at a
/// time. Should handling fall behind, the stream drops frames rather than
/// let them pile up.
///
/// Should the stream stop of itself — the window closed, the display gone —
/// `onStop` is told, once, on a queue of the system's.
final class FrameStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "OCRFlow.frames", qos: .userInteractive)
    private let onFrame: (CGImage) -> Void
    private let onStop: @Sendable () -> Void
    /// Behind `lock`: started and stopped from any thread.
    private var stream: SCStream?
    private let lock = NSLock()
    private var handlingSince: ContinuousClock.Instant?

    /// Handling a frame has been taking a while: whatever is scrolling it
    /// would do well to wait, or it runs ahead of what can be joined.
    var isBehind: Bool {
        lock.withLock { handlingSince.map { ContinuousClock.now - $0 > .milliseconds(50) } ?? false }
    }

    init(onFrame: @escaping (CGImage) -> Void, onStop: @escaping @Sendable () -> Void = {}) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// `size` is the picture's in pixels, as the first one taken.
    ///
    /// Over a region, none of OCRFlow's own windows is in the frames — not
    /// only those there when it starts but any shown later, a tooltip say:
    /// they are left out as one app's, not window by window. (Asked for
    /// what is on screen only, ScreenCaptureKit leaves out OCRFlow's panels
    /// over other apps, and OCRFlow with them: nothing would be left out.)
    func start(_ target: CaptureTarget, size: CGSize) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        switch target {
        case let .region(displayID, rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenGrabber.Failure.gone
            }
            let own = content.applications.filter { $0.processID == getpid() }
            filter = own.isEmpty
                ? SCContentFilter(display: display,
                                  excludingWindows: content.windows.filter { $0.owningApplication?.processID == getpid() })
                : SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            configuration.sourceRect = rect
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenGrabber.Failure.gone
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.ignoreShadowsSingleWindow = true
        }
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // As often as the screen changes: the more often, the less moves
        // between two frames, and the sooner the preview grows.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 4
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // Kept before it starts, so that a stop of its own is known as ours
        // however soon it comes.
        lock.withLock { self.stream = stream }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { self.stream = nil }
            throw error
        }
    }

    /// Runs `body` on the frames' queue, between frames.
    func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }

    /// Stops, and returns once the last frame has been handled: none is
    /// handed on after, and none is still being handled.
    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
        }
        // Frames are handled one at a time on `queue`: once this has run
        // there, any handed over before the stop has been handled.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let ours = lock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            self.stream = nil
            return true
        }
        if ours { onStop() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image else { return }
        lock.withLock { handlingSince = .now }
        onFrame(image)
        lock.withLock { handlingSince = nil }
    }
}
