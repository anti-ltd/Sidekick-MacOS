import SwiftUI
import iUX_MacOS

/// The single public surface for embedding Sidekick in a host app — same
/// shape as ClonkModule, so a future bundle app can mount both.
///
/// A host initialises one `SidekickModule`, calls `start()` after the app
/// finishes launching, then drops `rootView()` wherever the main UI should
/// live. The icon, menu-bar item and window scenes are standalone-only
/// concerns and live in `Sources/Sidekick`.
@MainActor
public final class SidekickModule: AppModule {

    // MARK: - Identity

    public static let moduleID    = "ltd.anti.sidekick"
    public static let displayName = "Sidekick"
    /// SF Symbol used by the menu-bar item, the sidebar row and the icon
    /// renderer. Picked for its "screen-being-mirrored" read.
    public static let symbolName  = "rectangle.inset.filled.on.rectangle"

    // MARK: - Core

    public let model: AppModel

    public required init() {
        model = AppModel()
    }

    /// Bring discovery online, restore the user's last role and prepare the
    /// transport. Call once after `applicationDidFinishLaunching`.
    public func start() {
        model.start()
    }

    /// Tear down discovery + any live session. Call from
    /// `applicationWillTerminate` so we don't leak a Bonjour advertisement.
    public func stop() {
        model.stop()
    }

    public var isMuted: Bool { !model.isActive }

    public func settingsView() -> AnyView {
        AnyView(SettingsRoot(model: model))
    }

    /// The full app UI — peer browser, role switcher, live session view. Use
    /// this rather than `settingsView()` when Sidekick is the *primary*
    /// surface of the host (i.e. inside the standalone Sidekick.app).
    public func rootView() -> AnyView {
        AnyView(SidekickRootView(model: model))
    }
}
