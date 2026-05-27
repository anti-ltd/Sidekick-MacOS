import Foundation
import Network
@preconcurrency import WebRTC

/// Client-side signaling. Opens an `NWConnection` to the peer's Bonjour
/// service, exchanges hello + offer/answer + ICE candidates, and hands
/// back a fully-wired `WebRTCTransport`.
///
/// Flow:
///   1. Open TCP to `peer.serviceName` on `_sidekick._tcp`.
///   2. Send `hello` carrying our protocol version + device UUID.
///   3. Receive `hello` from the host.
///   4. Create the `WebRTCTransport` (role: .client). Don't generate an
///      offer — we receive one from the host, since the host owns the
///      data-channel + video-track creation.
///   5. Apply remote offer, send local answer, exchange ICE candidates,
///      await `dataChannelOpen`.
@MainActor
public final class BonjourSignaling: Signaling {

    private var channel: SignalingChannel?
    private var driverTask: Task<Void, Error>?

    public init() {}

    public func connect(to peer: PeerDescriptor) async throws -> Transport {
        // Open to the Bonjour-advertised service. NWEndpoint.service lets
        // Network resolve the name + type for us.
        let endpoint = NWEndpoint.service(name: peer.serviceName,
                                          type: BonjourDiscovery.serviceType,
                                          domain: "local.", interface: nil)
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        let channel = SignalingChannel(connection: connection)
        self.channel = channel
        try await channel.start()

        // Hello handshake.
        let myID = LocalDeviceID.current
        try await channel.send(.hello(deviceID: myID))
        guard let hello = await channel.firstFrame(of: .hello) else {
            throw TransportError.signalingFailed("No hello from host")
        }
        _ = hello.protocolVersion // future: version negotiation

        // Build the client-side peer connection. Receives the data channel
        // + video track that the host's offer declares.
        let transport = try WebRTCTransport(role: .client)

        // Pump local ICE candidates outbound from this moment forward —
        // the peer connection has already started gathering.
        let candPump = Task {
            for await c in transport.outboundCandidates {
                try? await channel.send(.candidate(c))
            }
        }

        // Drive the SDP exchange.
        guard let offerFrame = await channel.firstFrame(of: .offer),
              let offer = offerFrame.sessionDescription(as: .offer) else {
            throw TransportError.signalingFailed("No offer from host")
        }
        try await transport.setRemoteDescription(offer)
        let answer = try await transport.makeAnswer()
        try await channel.send(.answer(answer))

        // Then keep applying any remote candidates that arrive after this.
        driverTask = Task {
            for await frame in channel.inbound where frame.kind == .candidate {
                if let c = frame.iceCandidate() {
                    try? await transport.add(remoteCandidate: c)
                }
            }
        }

        // Wait for the data channel to open before returning — at that
        // point the session can safely start sending RPCs.
        await transport.awaitDataChannelOpen()
        _ = candPump // keep alive — cancellation happens via stop().
        return transport
    }

    public func stop() {
        driverTask?.cancel()
        channel?.close()
        channel = nil
    }
}

// MARK: - Channel helpers

private extension SignalingChannel {
    /// Suspend until a frame of the given kind arrives (or the channel
    /// closes). Convenience for the linear parts of the handshake.
    func firstFrame(of kind: SignalingFrame.Kind) async -> SignalingFrame? {
        for await frame in inbound where frame.kind == kind {
            return frame
        }
        return nil
    }
}

// MARK: - Local device identity

/// Per-install UUID, persisted in `UserDefaults`. Shared with
/// `BonjourDiscovery` so the same identity is advertised in TXT records
/// and surfaced in signaling hellos.
enum LocalDeviceID {
    static var current: UUID {
        let key = "sidekick.localID"
        if let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
