import Foundation

/// One frame on the data channel. Every "deep integration" feature
/// (clipboard, files, URL bar, Claude mirror) is a `channel` + a `payload`,
/// so adding a new feature means adding a new `Channel` and a `Codable`
/// payload type — no wire-format surgery.
///
/// JSON for now. Tiny ASCII bursts (URL strings, clipboard text, RPC verbs)
/// dominate; we'll move to length-prefixed protobuf if a hot path ever
/// shows up in a profile.
public struct RPCEnvelope: Codable, Sendable {
    public let id: UUID
    public let channel: Channel
    public let kind: Kind
    /// Opaque to the envelope — each channel decodes this with its own type.
    public let payload: Data

    public enum Channel: String, Codable, Sendable {
        case input        // InputEvent
        case clipboard    // ClipboardChannel.Message
        case files        // FileChannel.Message
        case urlbar       // URLBarChannel.Message
        case claude       // ClaudeMirrorChannel.Message
        case meta         // Hello / pong / capabilities
    }

    public enum Kind: String, Codable, Sendable {
        case event        // fire-and-forget
        case request      // expects a `response` with the same id
        case response
    }

    public init(id: UUID = UUID(), channel: Channel, kind: Kind = .event, payload: Data) {
        self.id = id
        self.channel = channel
        self.kind = kind
        self.payload = payload
    }
}

public extension RPCEnvelope {
    /// Build an envelope from a `Codable` payload.
    static func event<P: Encodable>(_ channel: Channel, _ payload: P) throws -> RPCEnvelope {
        let data = try JSONEncoder().encode(payload)
        return RPCEnvelope(channel: channel, kind: .event, payload: data)
    }

    /// Decode `payload` as `T` — channel handlers call this on every inbound
    /// envelope for their channel.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: payload)
    }
}

/// Demux inbound envelopes to the right channel handler. One per session.
@MainActor
public final class RPCRouter {
    public typealias Handler = (RPCEnvelope) async -> Void
    private var handlers: [RPCEnvelope.Channel: Handler] = [:]

    public init() {}

    public func on(_ channel: RPCEnvelope.Channel, handle: @escaping Handler) {
        handlers[channel] = handle
    }

    public func route(_ envelope: RPCEnvelope) async {
        await handlers[envelope.channel]?(envelope)
    }

    /// Pump bytes off a transport and route them.
    public func consume(_ transport: Transport) async {
        let decoder = JSONDecoder()
        for await chunk in transport.incoming {
            do {
                let env = try decoder.decode(RPCEnvelope.self, from: chunk)
                await route(env)
            } catch {
                // Bad frame — log and keep going so a single garbled message
                // can't kill the session.
                print("Sidekick RPC: bad frame: \(error)")
            }
        }
    }
}
