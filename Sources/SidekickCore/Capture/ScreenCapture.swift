import Foundation
import CoreVideo

/// Stream the host Mac's screen as raw frames. The transport's internal
/// codec (WebRTC's video encoder) does the compression — we only owe it
/// `CVPixelBuffer`s + monotonic timestamps.
///
/// `prepare()` is split from `start(_:)` so the UI can show "Starting…"
/// while the ScreenCaptureKit handshake is in flight, then "Sharing" once
/// frames begin flowing.
public protocol ScreenCapture: AnyObject, Sendable {
    /// Bring up the underlying capture pipeline. Throws if the user
    /// hasn't granted Screen Recording yet — the caller can use that to
    /// surface a permissions hint inline.
    func prepare() async throws

    /// Begin pumping frames. The callback fires on a private serial queue;
    /// pushing into a `Transport` is safe because WebRTC's
    /// `RTCVideoSource` is internally synchronised. Idempotent.
    func start(_ onFrame: @escaping @Sendable (CVPixelBuffer, Int64) -> Void) async throws

    func stop() async
}
