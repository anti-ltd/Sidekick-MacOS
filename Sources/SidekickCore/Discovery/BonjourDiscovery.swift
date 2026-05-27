import Foundation
import Network
import Combine

/// `PeerDiscovery` backed by the modern Network framework. We use `NWBrowser`
/// to find peers and `NWListener` (in `BonjourSignaling`) to advertise — so
/// browsing and advertising are physically separate sockets and either can
/// be torn down without affecting the other.
///
/// Service type: `_sidekick._tcp`. Per-device identity is stable across
/// hostname changes via a UUID baked into the Bonjour TXT record.
@MainActor
public final class BonjourDiscovery: PeerDiscovery {

    public static let serviceType = "_sidekick._tcp"

    private let subject = CurrentValueSubject<[PeerDescriptor], Never>([])
    public var peers: AnyPublisher<[PeerDescriptor], Never> {
        subject.eraseToAnyPublisher()
    }

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var advertisedName: String?

    /// Stable per-install UUID — survives hostname changes, lets a peer
    /// recognise this device across launches. Persisted in UserDefaults.
    private let localID: UUID = {
        let key = "sidekick.localID"
        if let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    public init() {}

    // MARK: - Browsing

    public func startBrowsing(deviceName: String) {
        if browser != nil { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handle(results: results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func handle(results: Set<NWBrowser.Result>) {
        var peers: [PeerDescriptor] = []
        for r in results {
            guard case .bonjour(let txt) = r.metadata,
                  case .service(let name, _, _, _) = r.endpoint else {
                continue
            }
            let dict = txt.dictionary
            // Skip our own advertisement so we don't list ourselves.
            if let id = dict["id"], id == localID.uuidString { continue }

            let id = dict["id"].flatMap(UUID.init) ?? UUID()
            let modelRaw = dict["model"] ?? "unknown"
            let model = PeerDescriptor.DeviceModel(rawValue: modelRaw) ?? .unknown
            let version = dict["version"] ?? "?"
            let display = dict["name"] ?? name
            peers.append(PeerDescriptor(
                id: id,
                displayName: display,
                model: model,
                version: version,
                serviceName: name
            ))
        }
        subject.send(peers.sorted { $0.displayName < $1.displayName })
    }

    // MARK: - Advertising

    public func startAdvertising(deviceName: String) {
        guard listener == nil else { return }
        do {
            // includePeerToPeer enables AWDL — Apple's peer-to-peer Wi-Fi
            // stack — alongside regular IP. We need it because many home
            // routers (Eero, Orbi, modern ISP gear) ship with client
            // isolation on, which blocks all client-to-client traffic
            // including mDNS multicast. AWDL bypasses the router and
            // works between Apple devices on the same Wi-Fi regardless
            // of router policy — the same path AirDrop / AirPlay use.
            //
            // When true, NWListener may publish a UUID-named virtual
            // host (e.g. `d5d82805-….local`) in addition to the host's
            // real `.local` name; iOS NWBrowser with `includePeerToPeer`
            // resolves both via AWDL.
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)

            // Strip `.local` and any leading `.` from the service name —
            // ProcessInfo.hostName usually returns `<machine>.local`,
            // which Bonjour would embed verbatim (as `<machine>\.local`)
            // in the instance label. Clean names browse more reliably
            // and look right in the iOS peer list.
            let serviceName = Self.sanitiseServiceName(deviceName)

            var txt = NWTXTRecord()
            txt["id"]      = localID.uuidString
            txt["name"]    = serviceName
            txt["model"]   = "mac"
            txt["version"] = SidekickVersion.string
            listener.service = NWListener.Service(
                name: serviceName,
                type: Self.serviceType,
                domain: nil,
                txtRecord: txt
            )
            // Signaling sockets handed off to BonjourSignaling — see comments
            // in that file for how the SDP/ICE bytes flow over this NWListener.
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    self?.signalingConnectionsSubject.send(conn)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.advertisedName = deviceName
        } catch {
            // Surface this via a publisher once we add error reporting.
            print("Sidekick: failed to start Bonjour listener: \(error)")
        }
    }

    public func stopAdvertising() {
        listener?.cancel()
        listener = nil
        advertisedName = nil
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        stopAdvertising()
    }

    // MARK: - Signaling bridge

    /// Stream of inbound `NWConnection`s that a peer opened to our advertised
    /// service — consumed by `BonjourSignalingHost` to drive the SDP/ICE
    /// handshake. Kept here (rather than in a second listener) because
    /// Bonjour only lets one service own a name at a time.
    private let signalingConnectionsSubject = PassthroughSubject<NWConnection, Never>()
    public var signalingConnections: AnyPublisher<NWConnection, Never> {
        signalingConnectionsSubject.eraseToAnyPublisher()
    }

    /// Trim the trailing `.local` and other characters that don't belong
    /// in a Bonjour instance label. Exposed for tests.
    static func sanitiseServiceName(_ raw: String) -> String {
        var name = raw
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        if name.hasSuffix(".") { name.removeLast() }
        // Empty or all-whitespace falls back to a sensible default so
        // we don't ship an unbrowsable nameless service.
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Sidekick Mac" : trimmed
    }
}

