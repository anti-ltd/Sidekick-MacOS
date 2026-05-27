import SwiftUI
import iUX_MacOS

/// The main window content. Sidebar lists peers + role switcher, detail
/// shows the live session (or the role-picker placeholder when idle).
@MainActor
public struct SidekickRootView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPeer: PeerDescriptor?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Sidekick")
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoleSwitcher(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            List(selection: $selectedPeer) {
                Section("Peers on this network") {
                    if model.peers.isEmpty {
                        Text("Looking…")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(model.peers) { peer in
                            PeerRow(peer: peer)
                                .tag(peer)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: UX.sidebarMinWidth, ideal: UX.sidebarIdealWidth)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch model.session {
        case .connected(let session):
            ClientDisplayView(session: session, model: model)
        case .connecting(let peer):
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(peer.displayName)…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't connect",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .idle:
            idleDetail
        }
    }

    @ViewBuilder
    private var idleDetail: some View {
        switch model.role {
        case .host:
            HostStatusView(model: model)
        case .client:
            if let peer = selectedPeer {
                VStack(spacing: 16) {
                    Image(systemName: peer.model == .iPhone ? "iphone" : "macbook")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text(peer.displayName).font(.title2.weight(.semibold))
                    Button("Connect") {
                        model.connect(to: peer)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Pick a peer",
                    systemImage: "rectangle.dashed",
                    description: Text("Select a device on the left to connect.")
                )
            }
        case .idle:
            ContentUnavailableView(
                "Welcome to Sidekick",
                systemImage: SidekickModule.symbolName,
                description: Text("Pick Host to share this Mac, or Client to drive another device.")
            )
        }
    }
}

// MARK: - Subviews

private struct RoleSwitcher: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Role").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.role },
                set: { newRole in
                    switch newRole {
                    case .host:   model.becomeHost()
                    case .client: model.becomeClient()
                    case .idle:   model.goIdle()
                    }
                }
            )) {
                ForEach(AppModel.Role.allCases) { role in
                    Label(role.title, systemImage: role.symbol).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct PeerRow: View {
    let peer: PeerDescriptor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.displayName)
                Text(peer.model.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch peer.model {
        case .mac:     "macbook"
        case .iPhone:  "iphone"
        case .iPad:    "ipad"
        case .unknown: "questionmark.circle"
        }
    }
}
