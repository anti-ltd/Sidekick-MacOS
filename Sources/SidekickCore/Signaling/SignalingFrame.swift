import Foundation
@preconcurrency import WebRTC

/// One message on the signaling wire. Both `BonjourSignaling` (client
/// driver) and `BonjourSignalingHost` (host listener) speak the same
/// frame shape: length-prefixed JSON, one envelope per message.
///
/// The wire is reliable + ordered (TCP via NWConnection) so we don't
/// need sequence numbers — frames arrive in the order they were sent.
struct SignalingFrame: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello
        case offer
        case answer
        case candidate
        case bye
    }
    var kind: Kind

    // Filled in per kind. Unused fields are simply omitted from the JSON.
    var protocolVersion: String?     // hello
    var deviceID: String?            // hello
    /// Client → host: does this client want to receive the screen video
    /// track? Defaults to true on the wire (absent = true) for backwards
    /// compatibility. Set false for "remote control only" sessions —
    /// host skips the encoder entirely and saves ~4 Mbps + an encoder
    /// thread per connection.
    var wantsVideo: Bool?            // hello
    var sdp: String?                 // offer / answer
    var candidate: String?           // candidate
    var sdpMid: String?              // candidate
    var sdpMLineIndex: Int32?        // candidate
    var reason: String?              // bye
}

// MARK: - Convenience

extension SignalingFrame {
    static func hello(deviceID: UUID, wantsVideo: Bool = true) -> SignalingFrame {
        .init(
            kind: .hello,
            protocolVersion: SidekickVersion.string,
            deviceID: deviceID.uuidString,
            wantsVideo: wantsVideo
        )
    }

    static func offer(_ sdp: RTCSessionDescription) -> SignalingFrame {
        .init(kind: .offer, sdp: sdp.sdp)
    }

    static func answer(_ sdp: RTCSessionDescription) -> SignalingFrame {
        .init(kind: .answer, sdp: sdp.sdp)
    }

    static func candidate(_ c: RTCIceCandidate) -> SignalingFrame {
        .init(
            kind: .candidate,
            candidate: c.sdp,
            sdpMid: c.sdpMid,
            sdpMLineIndex: c.sdpMLineIndex
        )
    }

    /// Build an `RTCSessionDescription` of the given type from this frame's
    /// `sdp` field. Asserts in debug if `kind` doesn't match.
    func sessionDescription(as type: RTCSdpType) -> RTCSessionDescription? {
        guard let sdp else { return nil }
        return RTCSessionDescription(type: type, sdp: sdp)
    }

    func iceCandidate() -> RTCIceCandidate? {
        guard let s = candidate else { return nil }
        return RTCIceCandidate(sdp: s, sdpMLineIndex: sdpMLineIndex ?? 0, sdpMid: sdpMid)
    }
}
