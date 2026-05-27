import SwiftUI
import iUX

/// Detail pane when a client session is live. Remote video fills the canvas
/// via `RemoteVideoView` (RTCMTLNSVideoView); the URL bar and Claude
/// transcript overlay are pinned above it.
@MainActor
struct ClientDisplayView: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var model: AppModel
    @State private var urlField: String = ""

    var body: some View {
        VStack(spacing: 0) {
            urlBar
            Divider()
            ZStack {
                remoteVideoPlaceholder

                VStack {
                    Spacer()
                    if let text = session.latestTranscript, !text.isEmpty {
                        ClaudeTranscriptOverlay(text: text)
                            .padding(.bottom, 24)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Disconnect") { model.leave() }
            }
        }
        .onAppear {
            if let url = session.latestURL?.url { urlField = url }
        }
        .onChange(of: session.latestURL?.url ?? "") { _, new in
            urlField = new
        }
    }

    // MARK: - URL bar

    private var urlBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock").foregroundStyle(.secondary)
            TextField("Address", text: $urlField, onCommit: {
                Task { await session.setURL(urlField) }
            })
            .textFieldStyle(.plain)
            .font(.body.monospaced())
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    // MARK: - Video

    private var remoteVideoPlaceholder: some View {
        ZStack {
            Color.black
            RemoteVideoView(session: session)
        }
    }
}

// MARK: - Claude overlay

private struct ClaudeTranscriptOverlay: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .padding(14)
        .glassPanel(padding: 0)
    }
}

// MARK: - iUX.glassPanel bridge for Sidekick

private extension View {
    func glassPanel(padding: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: UX.panelCornerRadius)
                .fill(.black.opacity(UX.panelFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UX.panelCornerRadius)
                .strokeBorder(.white.opacity(UX.panelBorderOpacity), lineWidth: 1)
        )
    }
}
