import Foundation
import Network
import Combine

/// Find other Sidekick devices on the network and (optionally) advertise that
/// this one is host-ready. Both halves are deliberately separated so a
/// client-only device can browse without ever showing up in someone else's
/// browser.
@MainActor
public protocol PeerDiscovery: AnyObject {
    /// Live list of visible peers. Re-emits whenever the set changes.
    var peers: AnyPublisher<[PeerDescriptor], Never> { get }

    /// Inbound signaling connections from peers that opened a TCP socket
    /// to our advertised Bonjour service. Consumed by
    /// `BonjourSignalingHost`. Emits nothing on devices that aren't
    /// advertising.
    var signalingConnections: AnyPublisher<NWConnection, Never> { get }

    /// Start browsing. Idempotent.
    func startBrowsing(deviceName: String)
    /// Start advertising this device as host-ready. Idempotent.
    func startAdvertising(deviceName: String)

    func stopAdvertising()
    /// Stop both browsing and advertising and release any sockets.
    func stop()
}
