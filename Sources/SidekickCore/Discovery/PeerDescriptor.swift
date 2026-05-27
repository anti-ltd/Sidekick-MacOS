import Foundation

/// A peer Sidekick has seen on the local network — the unit a `PeerDiscovery`
/// publishes and the unit the UI shows in the browser. Identity is the
/// Bonjour-published UUID, not the host name, so a peer surviving a hostname
/// change still reads as the same device.
public struct PeerDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let displayName: String
    public let model: DeviceModel
    public let version: String
    /// The Bonjour service this peer is advertising — used by the signaling
    /// layer to open the SDP channel.
    public let serviceName: String

    public enum DeviceModel: String, Codable, Sendable {
        case mac, iPhone, iPad, unknown
    }

    public init(id: UUID, displayName: String, model: DeviceModel, version: String, serviceName: String) {
        self.id = id
        self.displayName = displayName
        self.model = model
        self.version = version
        self.serviceName = serviceName
    }
}
