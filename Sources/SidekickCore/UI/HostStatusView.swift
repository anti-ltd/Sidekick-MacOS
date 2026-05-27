import SwiftUI
import iUX

/// Detail pane in host mode — shows whether we're broadcasting, walks the
/// user through the Accessibility/Screen Recording grants, and lists
/// currently-connected peers.
@MainActor
struct HostStatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UX.cardSpacing) {
                statusBanner

                CardSection("Permissions") {
                    permissionRow(
                        title: "Accessibility",
                        subtitle: "Lets Sidekick relay keyboard and mouse from your other devices.",
                        state: model.permissions.accessibility,
                        grantAction: { model.permissions.requestAccessibility() },
                        settingsAction: { model.permissions.openAccessibilitySettings() }
                    )
                    Divider()
                    permissionRow(
                        title: "Screen Recording",
                        subtitle: "Lets Sidekick stream this Mac's display to your other devices.",
                        state: model.permissions.screenRecording,
                        grantAction: { model.permissions.requestScreenRecording() },
                        settingsAction: { model.permissions.openScreenRecordingSettings() }
                    )
                    Divider()
                    permissionRow(
                        title: "Local Network",
                        subtitle: "Lets Sidekick find your other devices over Wi-Fi using Bonjour.",
                        state: model.permissions.localNetwork,
                        grantAction: { model.permissions.openLocalNetworkSettings() },
                        settingsAction: { model.permissions.openLocalNetworkSettings() }
                    )
                }

                CardSection("Connected") {
                    if model.connectedClients.isEmpty {
                        Text("Waiting for a peer to connect. Open Sidekick on your phone or other Mac and tap this device.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, UX.rowVPadding)
                    } else {
                        ForEach(model.connectedClients) { peer in
                            HStack {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Image(systemName: peer.model == .iPhone ? "iphone" : "macbook")
                                    .foregroundStyle(.tint)
                                Text(peer.displayName)
                                Spacer()
                                Text(peer.version).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, UX.rowVPadding * 0.5)
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let (color, label, sub) = bannerCopy
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12)
            VStack(alignment: .leading) {
                Text(label).font(.headline)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var bannerCopy: (Color, String, String) {
        switch model.hostStatus {
        case .stopped:           (.gray,   "Not sharing", "Pick the Host role to start advertising on this network.")
        case .starting:          (.yellow, "Starting…",   "Bringing up the capture pipeline.")
        case .running:           (.green,  "Sharing",     "Your devices can find this Mac as \(model.deviceName).")
        case .failed(let msg):   (.red,    "Stopped",     msg)
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        state: Permissions.State,
        grantAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            case .denied:
                Button("Grant", action: grantAction)
            case .unknown:
                // Local Network on macOS — no preflight API, so we can't
                // assert green. Offer Settings instead of a "Grant" button,
                // which would imply we know it's denied.
                Button("Open Settings", action: settingsAction)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, UX.rowVPadding)
    }
}
