import AppKit
import SwiftUI
import iUX
import SidekickCore

// Sidekick — a remote desktop app with deep-integration extras.
//
// Structure:
//   • One main window (peer browser + live session view), driven by SidekickRootView.
//   • Menu-bar agent for quick role flips + a "currently sharing" indicator.
//   • AppDelegate owns the SidekickModule and the menu-bar host.
//
// Dev tool: `--icon <dir>` renders the AppIcon.iconset folder, then exits.
@main
struct SidekickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Sidekick") {
            SidekickWindow(model: appDelegate.sidekick.model)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // nothing to "New"
        }
        Settings { EmptyView() }
    }
}

/// Tiny shell that adopts the SidekickCore root view + applies the standard
/// minimum window size.
private struct SidekickWindow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SidekickRootView(model: model)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sidekick = SidekickModule()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--icon"), idx + 1 < args.count {
            AppIconRenderer.run(directory: args[idx + 1])
            NSApp.terminate(nil)
            return
        }

        // appstage screenshot mode: seed demo state, let the WindowGroup open,
        // wait for it to appear, then report the window ID. Compiled in only
        // for appstage capture builds (-DAPPSTAGE); absent from releases.
        #if APPSTAGE
        if let idx = args.firstIndex(of: "--appstage"), idx + 1 < args.count {
            AppStageDriver.run(state: args[idx + 1], model: sidekick.model)
            return
        }
        #endif

        menuBar = MenuBarController(
            symbolName: SidekickModule.symbolName,
            accessibilityLabel: SidekickModule.displayName,
            popoverSize: NSSize(width: UX.popoverWidth, height: 440),
            rootView: sidekick.settingsView(),
            menuProvider: { [weak self] in self?.contextMenu() }
        )
        sidekick.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidekick.stop()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(
            title: sidekick.model.isActive ? "Active" : "Idle",
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(.init(title: "Open Sidekick", action: #selector(menuOpen), keyEquivalent: "").then { $0.target = self })
        menu.addItem(.separator())
        menu.addItem(.init(title: "Quit Sidekick", action: #selector(menuQuit), keyEquivalent: "q").then { $0.target = self })
        return menu
    }

    @objc private func menuOpen() {
        // Bring the main window forward.
        for window in NSApp.windows where window.title == "Sidekick" {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}

private extension NSObject {
    func then(_ apply: (Self) -> Void) -> Self {
        apply(self); return self
    }
}
