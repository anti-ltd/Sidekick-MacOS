import Foundation
import CoreVideo
@preconcurrency import WebRTC

/// The medium a Sidekick session runs over — a bidirectional WebRTC peer
/// connection carrying one ordered data channel (for input events,
/// clipboard, file ops and every other RPC) and one video track per
/// direction (host → client only, for v0).
///
/// The protocol is small on purpose — sessions interact with WebRTC almost
/// entirely through this surface, so swapping codecs / wire-formats stays
/// a local change rather than rippling through the rest of the app.
public protocol Transport: AnyObject, Sendable {

    // MARK: - Data channel

    /// Send a chunk on the data channel. Reliable + ordered.
    func send(_ data: Data) async throws

    /// Stream of inbound data-channel chunks. Hot — subscribe before the
    /// peer starts sending or the opening RPCs will be missed.
    var incoming: AsyncStream<Data> { get }

    // MARK: - Video

    /// `true` if this session has a live video track in either direction.
    /// `false` in remote-only mode — `HostSession` checks this before
    /// spinning up `ScreenCaptureKit` so we don't capture frames we'd
    /// just throw away.
    var streamsVideo: Bool { get }

    /// Push one frame into the outbound video pipeline. The transport's
    /// internal encoder (the WebRTC encoder, for `WebRTCTransport`) takes
    /// it from here. No-op on transports that don't carry video — e.g.
    /// `LoopbackTransport` is RPC-only.
    func pushVideo(pixelBuffer: CVPixelBuffer, timestampNs: Int64)

    /// The remote peer's video track once it has arrived. `nil` until the
    /// PeerConnection has negotiated and the track callback has fired —
    /// renderers should observe this and attach themselves when it
    /// flips. Forever-`nil` on transports that don't carry video.
    var remoteVideoTrack: RTCVideoTrack? { get }

    /// Continuation that publishes `remoteVideoTrack` updates so SwiftUI
    /// views can react without polling.
    var remoteVideoTrackUpdates: AsyncStream<RTCVideoTrack?> { get }

    // MARK: - Lifecycle

    /// Fires once when the underlying connection becomes permanently
    /// unusable — ICE state goes `.failed`/`.closed`, the data channel
    /// closes, or the peer otherwise vanishes. Consumers subscribe to
    /// know when to tear down their session. The stream finishes after
    /// the single yield so re-subscribing won't replay.
    var terminated: AsyncStream<Void> { get }

    func close() async
}
