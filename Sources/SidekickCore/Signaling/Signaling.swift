import Foundation

/// Bring up a `Transport` to `peer`. Owns the SDP/ICE exchange (over Bonjour
/// in the `BonjourSignaling` implementation) and hands back a ready
/// `Transport` once the data + video channels are established.
@MainActor
public protocol Signaling: AnyObject {
    func connect(to peer: PeerDescriptor) async throws -> Transport
    /// Cancel any in-flight handshake and release sockets.
    func stop()
}
