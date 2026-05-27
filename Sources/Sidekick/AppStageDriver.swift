#if APPSTAGE
import AppKit
import SidekickCore

// Drives the Sidekick window for appstage screenshot capture.
//
// Flow:
//   1. Seed the AppModel with demo data (role, peers, session).
//   2. Let the SwiftUI WindowGroup open the main window normally.
//   3. Poll until the window appears, make it key, then print the
//      ready marker so appstage can screencapture and kill the process.
//
// The binary is built with -DAPPSTAGE (never shipped to users).
// See capture.mjs for the host side that consumes the ready marker.
@MainActor
enum AppStageDriver {

    static func run(state: String, model: AppModel) {
        seed(model, for: state)
        waitAndReport(state: state, attempts: 30)
    }

    // MARK: - Window discovery

    private static func waitAndReport(state: String, attempts: Int) {
        guard attempts > 0 else {
            emit(state: state, window: 0, w: 0, h: 0)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // The Sidekick WindowGroup opens a titled window; find it by title.
            let win = NSApp.windows.first { $0.isVisible && $0.title == "Sidekick" }
                   ?? NSApp.windows.first { $0.isVisible && !$0.frame.isEmpty }
            guard let win else {
                waitAndReport(state: state, attempts: attempts - 1)
                return
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // One extra tick so SwiftUI finishes layout at the new key state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                let f = win.frame
                emit(state: state, window: win.windowNumber, w: Int(f.width), h: Int(f.height))
            }
        }
    }

    private static func emit(state: String, window: Int, w: Int, h: Int) {
        print("@@APPSTAGE_READY@@ {\"window\":\(window),\"w\":\(w),\"h\":\(h),\"slug\":\"\(state)\"}")
        fflush(stdout)
    }

    // MARK: - Demo data

    private static func seed(_ model: AppModel, for state: String) {
        let phone = PeerDescriptor(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
            displayName: "x's iPhone 16 Pro",
            model: .iPhone,
            version: "1.0",
            serviceName: "sidekick-preview-phone"
        )
        let mac = PeerDescriptor(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
            displayName: "Mac Studio",
            model: .mac,
            version: "1.0",
            serviceName: "sidekick-preview-mac"
        )

        model.deviceName = "x's MacBook Pro"

        switch state {

        case "connect":
            // Client role, two peers visible — "Find your Mac instantly."
            model.seedForCapture(role: .client, peers: [phone, mac])

        case "host":
            // Host role, broadcasting, phone actively connected — "Share your screen in one click."
            model.seedForCapture(
                role: .host,
                peers: [phone],
                hostStatus: .running,
                connectedClients: [phone]
            )

        case "client":
            // Client role, connected — URL bar + Claude transcript overlay.
            let transport = LoopbackTransport()
            let session = ClientSession(
                peer: phone,
                transport: transport,
                injector: model.injector,
                clipboard: model.clipboard
            )
            session.seedForCapture(
                url: "github.com/counter-ltd/sidekick-mac",
                transcript: """
                → User
                what does the RPC layer carry?

                → Claude
                Five channels ride the data channel:

                  .input      — CGEvent keyboard & mouse
                  .urlbar     — host URL ↔ iOS field sync
                  .clipboard  — two-way pasteboard mirror
                  .files      — directory listing & transfer
                  .claude     — terminal transcript scrape

                Swap LoopbackTransport for the WebRTC data
                channel and everything above just works.
                """
            )
            model.seedForCapture(role: .client, peers: [phone], session: .connected(session))

        default:
            break
        }
    }
}
#endif
