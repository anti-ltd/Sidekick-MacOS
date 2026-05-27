import Foundation
import CoreVideo
// WebRTC's @objc classes (RTCVideoTrack, RTCIceCandidate, …) aren't marked
// Sendable, and we have no way to retrofit them. They're internally thread-
// safe per the libwebrtc contract; @preconcurrency tells Swift 6 to trust
// us when we shuttle them between actors below.
@preconcurrency import WebRTC

/// Real `Transport` backed by an `RTCPeerConnection`. One ordered/reliable
/// data channel (label `"sidekick.rpc"`) carries every RPC; one
/// `RTCVideoTrack` per direction carries the screen.
///
/// Construction flow:
///   1. Both peers create a `WebRTCTransport` with their role.
///   2. The caller (one of `BonjourSignaling` / `BonjourSignalingHost`)
///      drives the offer/answer/ICE exchange via the methods exposed on
///      `SignalingDriver`.
///   3. Once the data channel is open AND (host-side only) a remote
///      video track has been received, the transport is "live" and the
///      session can start pumping RPC + frames through it.
///
/// All callbacks from WebRTC arrive on internal libwebrtc threads. We
/// hop to the main actor in the published surface; the inner Sendable
/// state is guarded with a serial queue.
public final class WebRTCTransport: NSObject, Transport, @unchecked Sendable {

    // MARK: - Role

    public enum Role: Sendable { case host, client }

    // MARK: - Shared factory

    /// The peer-connection factory is expensive to spin up and intended to
    /// be a process singleton — `RTCInitializeSSL()` allocates global
    /// crypto state and shouldn't be called twice.
    nonisolated(unsafe) private static var sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    public static func bootstrap() {
        _ = sharedFactory
    }

    // MARK: - Connection state

    private let role: Role
    private let peer: RTCPeerConnection
    private var dataChannel: RTCDataChannel?
    /// `nil` when the session is remote-only (no screen stream). `pushVideo`
    /// no-ops, no encoder spins up, no bandwidth wasted.
    private let videoSource: RTCVideoSource?
    private let dummyCapturer: RTCVideoCapturer?
    private let videoSender: RTCRtpSender?

    public let streamsVideo: Bool

    public private(set) var remoteVideoTrack: RTCVideoTrack? {
        didSet { trackCont.yield(remoteVideoTrack) }
    }
    public let remoteVideoTrackUpdates: AsyncStream<RTCVideoTrack?>
    private let trackCont: AsyncStream<RTCVideoTrack?>.Continuation

    public let incoming: AsyncStream<Data>
    private let incomingCont: AsyncStream<Data>.Continuation

    /// Outbound ICE candidates as they're gathered locally — the signaling
    /// driver pulls these and sends them to the peer.
    public let outboundCandidates: AsyncStream<RTCIceCandidate>
    private let candCont: AsyncStream<RTCIceCandidate>.Continuation

    public let terminated: AsyncStream<Void>
    private let terminatedCont: AsyncStream<Void>.Continuation
    /// Guards the one-shot termination signal — ICE state and data
    /// channel state can both fire `.closed`/`.failed` for the same
    /// underlying death, but we want exactly one downstream event.
    private let terminationLock = NSLock()
    private var hasTerminated = false

    /// Fires once when the data channel is fully open + ready to read/write.
    private let dataChannelOpen = AsyncStreamOnce<Void>()

    // MARK: - Init

    /// - Parameters:
    ///   - role: `.host` or `.client`. Host opens the data channel + adds
    ///     the video track; client receives both via delegate callbacks.
    ///   - streamsVideo: whether this side participates in the video track.
    ///     Set to `false` for "remote control only" sessions where the
    ///     client doesn't need to see the host's screen — saves an encoder,
    ///     a decoder, and ~4 Mbps of bandwidth. Host honours the client's
    ///     `wantsVideo` from the hello frame; clients pass their own
    ///     preference.
    public init(role: Role, streamsVideo: Bool = true) throws {
        self.role = role
        self.streamsVideo = streamsVideo

        var trackCont: AsyncStream<RTCVideoTrack?>.Continuation!
        self.remoteVideoTrackUpdates = AsyncStream { trackCont = $0 }
        self.trackCont = trackCont

        var incCont: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { incCont = $0 }
        self.incomingCont = incCont

        var candCont: AsyncStream<RTCIceCandidate>.Continuation!
        self.outboundCandidates = AsyncStream { candCont = $0 }
        self.candCont = candCont

        var termCont: AsyncStream<Void>.Continuation!
        self.terminated = AsyncStream { termCont = $0 }
        self.terminatedCont = termCont

        // Standard configuration: Google's public STUN. TURN servers can be
        // appended once we have credentials.
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: [
                "stun:stun.l.google.com:19302",
                "stun:stun1.l.google.com:19302",
            ])
        ]
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.sharedFactory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TransportError.signalingFailed("Could not create RTCPeerConnection")
        }
        self.peer = peer

        // Outbound video pipeline. Skipped entirely when the session is
        // remote-only — no encoder, no track in the SDP, no bandwidth.
        if streamsVideo {
            let source = Self.sharedFactory.videoSource()
            self.videoSource = source
            self.dummyCapturer = RTCVideoCapturer(delegate: source)
            let videoTrack = Self.sharedFactory.videoTrack(with: source, trackId: "sidekick.video")
            self.videoSender = peer.add(videoTrack, streamIds: ["sidekick.stream"])
        } else {
            self.videoSource = nil
            self.dummyCapturer = nil
            self.videoSender = nil
        }

        super.init()
        peer.delegate = self

        // Bitrate cap + degradation preference. Without an explicit cap
        // WebRTC's congestion controller ramps up aggressively (we saw
        // 8 Mbps default) which thrashes on flaky home Wi-Fi. 4 Mbps
        // looks visually identical for screen content while halving
        // the network footprint. `maintainFramerate` drops resolution
        // before frame rate on bandwidth dips, which keeps the cursor
        // tracking smooth at the cost of some sharpness on static text.
        if let sender = videoSender {
            let params = sender.parameters
            if let enc = params.encodings.first {
                enc.maxBitrateBps = NSNumber(value: 4_000_000)
                enc.maxFramerate  = NSNumber(value: 30)
            }
            sender.parameters = params
        }

        if role == .host {
            // Host opens the data channel; the offer carries the m=
            // section so the client's delegate fires `didOpen`.
            let config = RTCDataChannelConfiguration()
            config.isOrdered = true
            config.isNegotiated = false
            let dc = peer.dataChannel(forLabel: "sidekick.rpc", configuration: config)
            dc?.delegate = self
            self.dataChannel = dc
        }
    }

    // MARK: - Transport

    public func send(_ data: Data) async throws {
        guard let dc = dataChannel else {
            throw TransportError.connectionLost("Data channel not yet open")
        }
        let buf = RTCDataBuffer(data: data, isBinary: true)
        dc.sendData(buf)
    }

    public func pushVideo(pixelBuffer: CVPixelBuffer, timestampNs: Int64) {
        // No-op when the session is remote-only (videoSource was never
        // created). The host's video pump still calls this, it just
        // returns immediately.
        guard let videoSource, let dummyCapturer else { return }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: timestampNs
        )
        videoSource.capturer(dummyCapturer, didCapture: frame)
    }

    public func close() async {
        signalTermination()
        peer.close()
        dataChannel?.close()
        incomingCont.finish()
        candCont.finish()
        trackCont.finish()
    }

    /// Fire the one-shot terminated signal. Called from ICE state
    /// changes, data-channel state changes, and `close()` — guarded so
    /// multiple call sites don't double-yield (they often all see the
    /// same underlying death).
    private func signalTermination() {
        terminationLock.lock()
        let alreadyDone = hasTerminated
        hasTerminated = true
        terminationLock.unlock()
        guard !alreadyDone else { return }
        terminatedCont.yield(())
        terminatedCont.finish()
    }

    // MARK: - Signaling driver surface
    //
    // BonjourSignaling and its host counterpart call these to drive the
    // peer connection through offer → answer → ICE exchange. Kept here
    // (rather than on a separate object) so all RTCPeerConnection
    // mutations are owned by the transport.

    public func makeOffer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            peer.offer(for: constraints) { sdp, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let sdp else { cont.resume(throwing: TransportError.signalingFailed("nil offer")); return }
                cont.resume(returning: sdp)
            }
        }
        try await setLocalDescription(offer)
        return offer
    }

    public func makeAnswer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            peer.answer(for: constraints) { sdp, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let sdp else { cont.resume(throwing: TransportError.signalingFailed("nil answer")); return }
                cont.resume(returning: sdp)
            }
        }
        try await setLocalDescription(answer)
        return answer
    }

    public func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    public func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(sdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    public func add(remoteCandidate candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.add(candidate) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    /// Suspends until the data channel hits `.open`, so callers can await
    /// "session is fully live" without polling.
    public func awaitDataChannelOpen() async {
        await dataChannelOpen.value
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCTransport: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            // Hop to main so SwiftUI observers see the change inside an
            // explicit, predictable schedule.
            Task { @MainActor [weak self] in
                self?.remoteVideoTrack = track
            }
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            Task { @MainActor [weak self] in
                self?.remoteVideoTrack = track
            }
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // `.disconnected` is transient — WebRTC may bring the link back
        // via ICE renegotiation, so we don't treat it as terminal.
        // `.failed` and `.closed` are permanent; fire the termination
        // signal so the session above us tears down.
        switch newState {
        case .failed, .closed:
            signalTermination()
        default:
            break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        candCont.yield(candidate)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Client-side path: the data channel is created by the host's
        // offer; we capture it here.
        dataChannel.delegate = self
        self.dataChannel = dataChannel
    }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCTransport: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            dataChannelOpen.resolve(())
        case .closed:
            // Belt and braces — ICE `.closed` usually beats this, but
            // if the peer closes only the data channel we still want
            // to tear the session down.
            signalTermination()
        default:
            break
        }
    }
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        incomingCont.yield(buffer.data)
    }
}

// MARK: - One-shot signal

/// Tiny awaitable that fires exactly once. Used to suspend until the data
/// channel is open without exposing the underlying continuation.
public final class AsyncStreamOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value_: T?
    private var waiters: [CheckedContinuation<T, Never>] = []

    public init() {}

    public func resolve(_ value: T) {
        lock.lock()
        if value_ != nil { lock.unlock(); return }
        value_ = value
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for w in waiters { w.resume(returning: value) }
    }

    public var value: T {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
                lock.lock()
                if let v = value_ { lock.unlock(); cont.resume(returning: v); return }
                waiters.append(cont)
                lock.unlock()
            }
        }
    }
}

// MARK: - TransportError

public enum TransportError: Error, CustomStringConvertible {
    case notImplemented(String)
    case signalingFailed(String)
    case connectionLost(String)

    public var description: String {
        switch self {
        case .notImplemented(let s): "Not implemented: \(s)"
        case .signalingFailed(let s): "Signaling failed: \(s)"
        case .connectionLost(let s): "Connection lost: \(s)"
        }
    }
}
