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
final class FrameStream: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "OCRFlow.frames", qos: .userInteractive)
    private let onFrame: (CGImage) -> Void
    private var stream: SCStream?
    private let lock = NSLock()
    private var handlingSince: ContinuousClock.Instant?

    /// Handling a frame has been taking a while: whatever is scrolling it
    /// would do well to wait, or it runs ahead of what can be joined.
    var isBehind: Bool {
        lock.withLock { handlingSince.map { ContinuousClock.now - $0 > .milliseconds(50) } ?? false }
    }

    init(onFrame: @escaping (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    /// `size` is the picture's in pixels, as the first one taken; `excluding`
    /// OCRFlow's own windows over a region.
    func start(_ target: CaptureTarget, size: CGSize, excluding windowIDs: [CGWindowID]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        switch target {
        case let .region(displayID, rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenGrabber.Failure.gone
            }
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { windowIDs.contains($0.windowID) })
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Runs `body` on the frames' queue, between frames.
    func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }

    /// Stops, and returns once the last frame has been handled.
    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
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
