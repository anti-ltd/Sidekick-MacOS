import SwiftUI
import AppKit
@preconcurrency import WebRTC

/// SwiftUI host for `RTCMTLNSVideoView` — the macOS Metal-backed renderer
/// shipped by stasel/WebRTC. Watches the session for the inbound video
/// track and (re)attaches the renderer whenever the track changes.
///
/// Why this rather than a `MTKView` we drive ourselves: WebRTC owns the
/// decoder + frame timing already; piping decoded frames out to do our
/// own Metal upload would just duplicate work. The native renderer also
/// handles aspect-fit and resize for free.
struct RemoteVideoView: NSViewRepresentable {
    @ObservedObject var session: ClientSession

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: .zero)
        context.coordinator.attach(view: view, session: session)
        return view
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
        // The coordinator already mirrors session.transport.remoteVideoTrack
        // via an async observer; nothing to do per-update.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private var task: Task<Void, Never>?
        private weak var attached: RTCVideoTrack?

        func attach(view: RTCMTLNSVideoView, session: ClientSession) {
            // Apply the current track immediately if it's already arrived.
            if let track = session.transport.remoteVideoTrack {
                track.add(view); attached = track
            }
            task?.cancel()
            task = Task { [weak view] in
                for await track in session.transport.remoteVideoTrackUpdates {
                    guard let view else { return }
                    // Detach the previous renderer (if any) so we don't end
                    // up driving stale tracks after a reconnect.
                    self.attached?.remove(view)
                    track?.add(view)
                    self.attached = track
                }
            }
        }

        deinit { task?.cancel() }
    }
}
