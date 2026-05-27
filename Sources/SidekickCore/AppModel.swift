import Foundation
import Combine
import SwiftUI

/// Top-level observable state. Owns the discovery service, the active
/// session (if any) and the user's role preference. Every view binds to
/// this one object.
@MainActor
public final class AppModel: ObservableObject {

    // MARK: - Role

    /// Sidekick is dual-mode. The user picks which mode this Mac is in;
    /// the choice is persisted so re-launching restores the previous role.
    public enum Role: String, CaseIterable, Identifiable {
        /// Sharing this Mac's screen + input.
        case host
        /// Driving another Mac (or another iOS device).
        case client
        /// Neither — idle, ready to flip into either.
        case idle

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .host:   "Host"
            case .client: "Client"
            case .idle:   "Idle"
            }
        }

        public var symbol: String {
            switch self {
            case .host:   "wave.3.right"
            case .client: "rectangle.on.rectangle"
            case .idle:   "moon"
            }
        }
    }

    // MARK: - Published state

    @Published public private(set) var role: Role = .idle
    @Published public private(set) var peers: [PeerDescriptor] = []
    @Published public private(set) var session: SessionState = .idle
    @Published public private(set) var hostStatus: HostStatus = .stopped
    /// Connected client peers, while we're in host mode. One entry per
    /// live `HostSession` — surfaced in `HostStatusView` so the user can
    /// see who's currently driving them.
    @Published public private(set) var connectedClients: [PeerDescriptor] = []
    @Published public var deviceName: String = ProcessInfo.processInfo.hostName

    /// Convenience for the menu-bar / sidebar status indicator.
    public var isActive: Bool {
        if case .connected = session { return true }
        if case .running = hostStatus { return true }
        return false
    }

    // MARK: - Services

    public let discovery: PeerDiscovery
    public let signaling: Signaling
    public let injector: InputInjector
    public let capture: ScreenCapture
    public let clipboard: ClipboardChannel
    public let permissions = Permissions()

    private var signalingHost: BonjourSignalingHost?
    private var hostSessions: [HostSession] = []
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    public init(
        discovery: PeerDiscovery = BonjourDiscovery(),
        signaling: Signaling = BonjourSignaling(),
        injector: InputInjector = CGEventInjector(),
        capture: ScreenCapture = ScreenCaptureKitCapture(),
        clipboard: ClipboardChannel = NSPasteboardClipboardChannel()
    ) {
        self.discovery = discovery
        self.signaling = signaling
        self.injector  = injector
        self.capture   = capture
        self.clipboard = clipboard
    }

    // MARK: - Lifecycle

    public func start() {
        permissions.start()
        // Any peer surfacing on Bonjour means our Local Network grant is
        // working — we use that as the de-facto signal since macOS has no
        // public API to query the LN privacy state directly.
        discovery.peers
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] peers in
                if !peers.isEmpty { self?.permissions.noteLocalNetworkActivity() }
            })
            .assign(to: &$peers)
        discovery.startBrowsing(deviceName: deviceName)

        // Restore the last role the user picked so `make run` (which
        // relaunches the app) doesn't drop them back to .idle every
        // rebuild — they'd have to re-click Host every iteration.
        if let saved = UserDefaults.standard.string(forKey: "sidekick.role"),
           let role = Role(rawValue: saved) {
            switch role {
            case .host:   becomeHost()
            case .client: becomeClient()
            case .idle:   break
            }
        }
    }

    public func stop() {
        discovery.stop()
        signaling.stop()
        leave()
    }

    // MARK: - Role transitions

    /// Flip into host mode. Starts advertising on Bonjour, brings up the
    /// signaling host (so inbound peers can actually open a session),
    /// and pre-warms the screen capture pipeline so a connecting client
    /// sees video within a frame or two of the SDP handshake completing.
    public func becomeHost() {
        role = .host
        UserDefaults.standard.set(Role.host.rawValue, forKey: "sidekick.role")
        hostStatus = .starting

        // Each accepted peer gets its own ScreenCapture instance — sharing
        // one would clash on SCStream's single-output model. The factory
        // closure runs on MainActor so it's safe to construct from any
        // thread the signaling host calls us back on.
        let captureFactory: @MainActor () -> ScreenCapture = { ScreenCaptureKitCapture() }
        let signalingHost = BonjourSignalingHost(
            injector: injector,
            captureFactory: captureFactory,
            clipboard: clipboard
        ) { [weak self] hostSession in
            self?.handle(newHostSession: hostSession)
        }
        signalingHost.start(connections: discovery.signalingConnections)
        self.signalingHost = signalingHost

        discovery.startAdvertising(deviceName: deviceName)

        Task { @MainActor in
            do {
                try await capture.prepare()
                hostStatus = .running
            } catch {
                hostStatus = .failed("\(error)")
                role = .idle
            }
        }
    }

    /// Flip into client mode. Stops advertising; we don't want to show up in
    /// other peers' browsers while we're trying to drive them.
    public func becomeClient() {
        role = .client
        UserDefaults.standard.set(Role.client.rawValue, forKey: "sidekick.role")
        hostStatus = .stopped
        discovery.stopAdvertising()
        teardownHostSessions()
    }

    /// Drop back to idle without tearing the discovery service down.
    public func goIdle() {
        leave()
        role = .idle
        UserDefaults.standard.set(Role.idle.rawValue, forKey: "sidekick.role")
        discovery.stopAdvertising()
        teardownHostSessions()
    }

    private func handle(newHostSession session: HostSession) {
        // A successful inbound signaling connection is also strong evidence
        // Local Network is allowed (the connection had to traverse mDNS).
        permissions.noteLocalNetworkActivity()
        hostSessions.append(session)
        connectedClients.append(session.peer)
    }

    private func teardownHostSessions() {
        signalingHost?.stop()
        signalingHost = nil
        for s in hostSessions { s.stop() }
        hostSessions.removeAll()
        connectedClients.removeAll()
    }

    // MARK: - Session

    /// Attempt to connect to `peer` as a client. The transport is created
    /// here and lives for the duration of the session.
    public func connect(to peer: PeerDescriptor) {
        guard role == .client else { return }
        session = .connecting(peer)
        Task { @MainActor in
            do {
                let transport = try await signaling.connect(to: peer)
                let client = ClientSession(peer: peer, transport: transport, injector: injector, clipboard: clipboard)
                session = .connected(client)
                try await client.start()
            } catch {
                session = .failed("\(error)")
            }
        }
    }

    public func leave() {
        if case .connected(let s) = session { s.stop() }
        session = .idle
    }

#if APPSTAGE
    // MARK: - Appstage capture seeding

    /// Pre-populate observable state so the window renders the desired shot
    /// without starting real networking. Called by AppStageDriver before the
    /// SwiftUI window renders.
    public func seedForCapture(
        role: Role,
        peers: [PeerDescriptor],
        session: SessionState = .idle,
        hostStatus: HostStatus = .stopped,
        connectedClients: [PeerDescriptor] = []
    ) {
        self.role             = role
        self.peers            = peers
        self.session          = session
        self.hostStatus       = hostStatus
        self.connectedClients = connectedClients
    }
#endif
}

// MARK: - Session shape

public enum SessionState {
    case idle
    case connecting(PeerDescriptor)
    case connected(ClientSession)
    case failed(String)
}

public enum HostStatus: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}
