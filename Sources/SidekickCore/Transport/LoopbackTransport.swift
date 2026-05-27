import Foundation
import CoreVideo
@preconcurrency import WebRTC

/// An in-process `Transport` used by unit tests and the dev "test mode"
/// toggle. Two endpoints share a pair of `AsyncStream`s; sending on one
/// surfaces on the other's `incoming`. No sockets, no codecs, no WebRTC
/// peer connection — strictly the RPC data channel.
///
/// Loopback deliberately doesn't carry video. Tests that need a video
/// path should spin up a real `WebRTCTransport` against a localhost
/// signaling pair instead.
public final class LoopbackTransport: Transport, @unchecked Sendable {

    private let dataContinuation: AsyncStream<Data>.Continuation
    public let incoming: AsyncStream<Data>

    public let streamsVideo: Bool = false
    public let remoteVideoTrack: RTCVideoTrack? = nil
    public let remoteVideoTrackUpdates: AsyncStream<RTCVideoTrack?>
    private let videoTrackCont: AsyncStream<RTCVideoTrack?>.Continuation

    weak var peer: LoopbackTransport?

    public init() {
        var dc: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { dc = $0 }
        self.dataContinuation = dc

        var vc: AsyncStream<RTCVideoTrack?>.Continuation!
        self.remoteVideoTrackUpdates = AsyncStream { vc = $0 }
        self.videoTrackCont = vc
    }

    /// Bind two transports as each other's peer.
    public static func pair() -> (LoopbackTransport, LoopbackTransport) {
        let a = LoopbackTransport(); let b = LoopbackTransport()
        a.peer = b; b.peer = a
        return (a, b)
    }

    public func send(_ data: Data) async throws {
        peer?.dataContinuation.yield(data)
    }

    public func pushVideo(pixelBuffer: CVPixelBuffer, timestampNs: Int64) {
        // No-op — see comment at the top of the file.
    }

    public func close() async {
        dataContinuation.finish()
        videoTrackCont.finish()
    }
}
