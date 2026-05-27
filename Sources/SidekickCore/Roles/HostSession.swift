import Foundation

/// One incoming connection on the host side. Wires the inbound input
/// channel to the `InputInjector`, runs the URL-bar / Claude-mirror /
/// clipboard / file adapters, and pumps the screen capture into the
/// transport.
@MainActor
public final class HostSession {
    public let peer: PeerDescriptor
    public let transport: Transport
    let injector: InputInjector
    let capture: ScreenCapture
    let clipboard: ClipboardChannel
    let urlBar = URLBarHostAdapter()
    let claude = ClaudeMirrorHostAdapter()
    let files = FileHostAdapter()
    let router = RPCRouter()

    private var pumpTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?

    public init(peer: PeerDescriptor, transport: Transport, injector: InputInjector,
                capture: ScreenCapture, clipboard: ClipboardChannel) {
        self.peer = peer
        self.transport = transport
        self.injector = injector
        self.capture = capture
        self.clipboard = clipboard
    }

    public func start() async throws {
        // Inbound: input events go to the injector.
        router.on(.input) { [weak self] env in
            guard let self, let event = try? env.decode(InputEvent.self) else { return }
            await self.injector.apply(event)
        }
        // Inbound: URL bar requests.
        router.on(.urlbar) { [weak self] env in
            guard let self, let msg = try? env.decode(URLBarChannel.Message.self) else { return }
            await MainActor.run { self.urlBar.apply(msg) }
        }
        // Inbound: Claude mirror requests.
        router.on(.claude) { [weak self] env in
            guard let self, let msg = try? env.decode(ClaudeMirrorChannel.Message.self) else { return }
            await MainActor.run { self.claude.apply(msg) }
        }
        // Inbound: clipboard updates from the peer.
        router.on(.clipboard) { [weak self] env in
            guard let self, let msg = try? env.decode(ClipboardMessage.self) else { return }
            await MainActor.run { self.clipboard.apply(msg) }
        }
        // Inbound: file ops.
        router.on(.files) { [weak self] env in
            guard let self, let msg = try? env.decode(FileChannel.Message.self) else { return }
            let reply = await self.files.handle(msg)
            try? await self.send(.files, reply)
        }

        // Outbound adapters.
        urlBar.start { [weak self] msg in
            try? await self?.send(.urlbar, msg)
        }
        claude.start { [weak self] msg in
            try? await self?.send(.claude, msg)
        }
        clipboard.start { [weak self] msg in
            try? await self?.send(.clipboard, msg)
        }

        // Inbound pump.
        pumpTask = Task { [router, transport] in
            await router.consume(transport)
        }
        // Outbound video — capture pushes pixel buffers directly into the
        // transport's encoder. No intermediate queue: WebRTC's
        // RTCVideoSource is happy to be called from any thread.
        //
        // Remote-only sessions skip this entirely — the client opted out
        // of receiving video, so capturing frames just to throw them
        // away would be a pointless cost.
        if transport.streamsVideo {
            try await capture.start { [transport] pixelBuffer, ts in
                transport.pushVideo(pixelBuffer: pixelBuffer, timestampNs: ts)
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        videoTask?.cancel()
        urlBar.stop()
        claude.stop()
        clipboard.stop()
        let cap = capture
        let trans = transport
        Task {
            await cap.stop()
            await trans.close()
        }
    }

    private func send<P: Encodable>(_ channel: RPCEnvelope.Channel, _ payload: P) async throws {
        let env = try RPCEnvelope.event(channel, payload)
        let data = try JSONEncoder().encode(env)
        try await transport.send(data)
    }
}
