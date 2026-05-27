import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// `ScreenCapture` backed by ScreenCaptureKit. We deliberately do *not*
/// encode here — WebRTC's `RTCVideoSource` owns the encoder, so this
/// class is just a frame source: native-resolution CVPixelBuffers at up
/// to 60fps, with a monotonic timestamp per frame.
///
/// The cursor is included so the iOS client sees where it's pointing.
public final class ScreenCaptureKitCapture: NSObject, ScreenCapture, SCStreamOutput, @unchecked Sendable {

    /// Callback handed in via `start(_:)`. Stored so `SCStreamOutput`
    /// callbacks (which arrive on a private queue) can forward each frame
    /// without re-wiring the delegate. Mutation gated by the queue.
    private var onFrame: (@Sendable (CVPixelBuffer, Int64) -> Void)?

    private var stream: SCStream?
    private var prepared = false

    public override init() { super.init() }

    // MARK: - Lifecycle

    public func prepare() async throws {
        guard !prepared else { return }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Cap capture at 1080p-ish — sending native Retina (5K on a Studio
        // Display) to a phone is a massive waste of encode + transmit
        // budget, and WebRTC will downscale anyway. Preserve aspect by
        // scaling the longest edge to ~1920 instead of hardcoding both.
        let scale = min(1920.0 / Double(display.width), 1.0)
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        // 30fps is the sweet spot — 60fps doubles cost without
        // perceptibly helping screen content (mostly text + scroll).
        // We can expose this as a quality knob later.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        self.stream = stream
        prepared = true
    }

    public func start(_ onFrame: @escaping @Sendable (CVPixelBuffer, Int64) -> Void) async throws {
        if !prepared { try await prepare() }
        self.onFrame = onFrame
        try await stream?.startCapture()
    }

    public func stop() async {
        try? await stream?.stopCapture()
        onFrame = nil
        prepared = false
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ns = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        onFrame?(pb, ns)
    }
}

public enum CaptureError: Error {
    case noDisplay
    case permissionDenied
}
