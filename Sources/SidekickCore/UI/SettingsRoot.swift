import SwiftUI
import iUX_MacOS

/// The settings popover content — wired into the iUX-MacOS menu-bar host. Tabs
/// match Clonk's pattern: General / About.
struct SettingsRoot: View {
    @ObservedObject var model: AppModel
    @State private var tab: Tab = .general

    enum Tab: String, SettingsTab {
        case general, about
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .about:   "info.circle"
            }
        }
    }

    var body: some View {
        SettingsPopover(selection: $tab) { tab in
            switch tab {
            case .general:
                CardSection("Device") {
                    HStack {
                        Text("Name")
                        TextField("Device name", text: $model.deviceName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.vertical, UX.rowVPadding)
                }
                CardSection("Status") {
                    HStack {
                        Text("Role")
                        Spacer()
                        Text(model.role.title).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, UX.rowVPadding)
                    Divider()
                    HStack {
                        Text("Visible peers")
                        Spacer()
                        Text("\(model.peers.count)").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, UX.rowVPadding)
                }
            case .about:
                CardSection {
                    HStack {
                        Image(systemName: SidekickModule.symbolName)
                            .font(.system(size: 28))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("Sidekick").font(.headline)
                            Text("v\(SidekickVersion.string)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, UX.rowVPadding)
                }
            }
        }
    }
}
