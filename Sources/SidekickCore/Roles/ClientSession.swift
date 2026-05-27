import Foundation
import Combine

/// One live "I am driving the other Mac" session. Owns the transport, the
/// RPC router, and the per-channel client-side bookkeeping (latest URL,
/// most recent clipboard, latest Claude snapshot).
@MainActor
public final class ClientSession: ObservableObject {
    public let peer: PeerDescriptor
    public let transport: Transport
    public let injector: InputInjector
    public let clipboard: ClipboardChannel
    public let router = RPCRouter()

    @Published public private(set) var latestURL: URLBarChannel.Message?
    @Published public private(set) var latestTranscript: String?
    @Published public private(set) var fileListing: [FileChannel.Entry] = []

    private var pumpTask: Task<Void, Never>?

    public init(peer: PeerDescriptor, transport: Transport, injector: InputInjector, clipboard: ClipboardChannel) {
        self.peer = peer
        self.transport = transport
        self.injector = injector
        self.clipboard = clipboard
    }

    /// Wire up the router + start the inbound pump. Returns once the loop is
    /// running; the loop itself keeps going until the transport closes.
    public func start() async throws {
        router.on(.urlbar) { [weak self] env in
            guard let self, let msg = try? env.decode(URLBarChannel.Message.self) else { return }
            await MainActor.run { self.latestURL = msg }
        }
        router.on(.claude) { [weak self] env in
            guard let self, let msg = try? env.decode(ClaudeMirrorChannel.Message.self) else { return }
            await MainActor.run { self.latestTranscript = msg.text }
        }
        router.on(.clipboard) { [weak self] env in
            guard let self, let msg = try? env.decode(ClipboardMessage.self) else { return }
            await MainActor.run { self.clipboard.apply(msg) }
        }
        router.on(.files) { [weak self] env in
            guard let self, let msg = try? env.decode(FileChannel.Message.self) else { return }
            if msg.kind == .listResult, let entries = msg.entries {
                await MainActor.run { self.fileListing = entries }
            }
        }

        // Outbound clipboard
        clipboard.start { [weak self] msg in
            try? await self?.send(channel: .clipboard, payload: msg)
        }

        pumpTask = Task { [router, transport] in
            await router.consume(transport)
        }
    }

    public func stop() {
        pumpTask?.cancel()
        clipboard.stop()
        Task { await transport.close() }
    }

    // MARK: - Outbound

    public func send(input event: InputEvent) async {
        try? await send(channel: .input, payload: event)
    }

    public func setURL(_ url: String) async {
        try? await send(channel: .urlbar, payload: URLBarChannel.Message(kind: .setURL, url: url))
    }

    public func requestFileListing(path: String) async {
        try? await send(channel: .files, payload: FileChannel.Message(kind: .list, path: path))
    }

    private func send<P: Encodable>(channel: RPCEnvelope.Channel, payload: P) async throws {
        let env = try RPCEnvelope.event(channel, payload)
        let data = try JSONEncoder().encode(env)
        try await transport.send(data)
    }

#if APPSTAGE
    /// Pre-populate the session's observable state for appstage capture shots.
    public func seedForCapture(url: String? = nil, transcript: String? = nil) {
        if let url {
            latestURL = URLBarChannel.Message(kind: .currentURL, url: url)
        }
        if let transcript {
            latestTranscript = transcript
        }
    }
#endif
}
