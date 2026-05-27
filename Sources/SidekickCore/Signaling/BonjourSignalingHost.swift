import Foundation
import Network
import Combine
@preconcurrency import WebRTC

/// Host-side counterpart to `BonjourSignaling`. Owns the inbound
/// connection queue from `BonjourDiscovery.signalingConnections` and,
/// for each connection, drives the SDP/ICE exchange + hands back a
/// running `WebRTCTransport` and a fresh `HostSession`.
///
/// Lifecycle: `start()` once when the host flips into Host role,
/// `stop()` when it leaves. The class is single-instance — multiple
/// concurrent peers each get their own `HostSession` but funnel
/// through the same signaling listener.
@MainActor
public final class BonjourSignalingHost {

    public typealias OnSession = @MainActor (HostSession) -> Void

    private let injector: InputInjector
    private let captureFactory: @MainActor () -> ScreenCapture
    private let clipboard: ClipboardChannel
    private let onSession: OnSession

    private var subscription: AnyCancellable?

    public init(
        injector: InputInjector,
        captureFactory: @escaping @MainActor () -> ScreenCapture,
        clipboard: ClipboardChannel,
        onSession: @escaping OnSession
    ) {
        self.injector = injector
        self.captureFactory = captureFactory
        self.clipboard = clipboard
        self.onSession = onSession
    }

    /// Begin accepting peer connections. Idempotent.
    public func start(connections: AnyPublisher<NWConnection, Never>) {
        subscription = connections.sink { [weak self] conn in
            Task { @MainActor in
                await self?.handle(connection: conn)
            }
        }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    // MARK: - One connection

    private func handle(connection: NWConnection) async {
        let channel = SignalingChannel(connection: connection)
        do {
            try await channel.start()

            // Hello first — confirms protocol version + peer identity.
            try await channel.send(.hello(deviceID: LocalDeviceID.current))
            guard let helloFrame = await channel.firstFrame(of: .hello),
                  let peerIDString = helloFrame.deviceID,
                  let peerID = UUID(uuidString: peerIDString) else {
                channel.close()
                return
            }

            // Build the host-side peer connection. Host opens the data
            // channel + adds the video track, so it generates the offer.
            // Honour the client's wantsVideo preference — when false the
            // video track is skipped entirely (no encoder, no bandwidth).
            // Absent (older clients) defaults to true.
            let wantsVideo = helloFrame.wantsVideo ?? true
            let transport = try WebRTCTransport(role: .host, streamsVideo: wantsVideo)

            // Pump local ICE outbound — this can race against the answer,
            // which is fine: WebRTC tolerates trickle ICE.
            let candPump = Task {
                for await c in transport.outboundCandidates {
                    try? await channel.send(.candidate(c))
                }
            }

            let offer = try await transport.makeOffer()
            try await channel.send(.offer(offer))

            guard let answerFrame = await channel.firstFrame(of: .answer),
                  let answer = answerFrame.sessionDescription(as: .answer) else {
                channel.close(); candPump.cancel(); return
            }
            try await transport.setRemoteDescription(answer)

            // Apply any remote candidates that follow.
            let candTask = Task {
                for await frame in channel.inbound where frame.kind == .candidate {
                    if let c = frame.iceCandidate() {
                        try? await transport.add(remoteCandidate: c)
                    }
                }
            }
            _ = candTask

            // Suspend until DC is open, then publish the session.
            await transport.awaitDataChannelOpen()

            let peer = PeerDescriptor(
                id: peerID,
                displayName: "Peer \(peerIDString.prefix(8))",
                model: .unknown,
                version: helloFrame.protocolVersion ?? "?",
                serviceName: ""
            )
            let session = HostSession(
                peer: peer,
                transport: transport,
                injector: injector,
                capture: captureFactory(),
                clipboard: clipboard
            )
            try await session.start()
            onSession(session)
            _ = candPump
        } catch {
            print("Sidekick host signaling: \(error)")
            channel.close()
        }
    }
}

// Borrowed from BonjourSignaling.swift — keeps the file self-contained.
private extension SignalingChannel {
    func firstFrame(of kind: SignalingFrame.Kind) async -> SignalingFrame? {
        for await frame in inbound where frame.kind == kind {
            return frame
        }
        return nil
    }
}
