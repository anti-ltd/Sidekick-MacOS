import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// Probes the three OS grants Sidekick needs to host a session.
/// `HostStatusView` polls this once a second so toggles flip in real-time
/// when the user grants in System Settings.
///
/// macOS has no public API to query Local Network access — the best signal
/// is "have we successfully discovered or accepted a peer". `AppModel`
/// drives that bit; everything else is a direct OS query.
@MainActor
public final class Permissions: ObservableObject {

    public enum State: Equatable {
        case granted
        case denied
        /// We can't tell — used for Local Network on macOS, where there's
        /// no preflight API. The row stays neutral with a "Open Settings"
        /// hint rather than a misleading red dot.
        case unknown
    }

    @Published public private(set) var accessibility: State = .unknown
    @Published public private(set) var screenRecording: State = .unknown
    @Published public private(set) var localNetwork: State = .unknown

    private var timer: Timer?

    public init() {}

    /// Begin polling. Idempotent — calling twice doesn't double up the timer.
    public func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate(); timer = nil
    }

    /// Called by `BonjourDiscovery` when the first peer appears or a peer
    /// successfully opens a signaling connection — strong evidence the
    /// Local Network grant is in place.
    public func noteLocalNetworkActivity() {
        if localNetwork != .granted { localNetwork = .granted }
    }

    public func refresh() {
        let ax: State = AXIsProcessTrusted() ? .granted : .denied
        if ax != accessibility { accessibility = ax }

        let sr: State = CGPreflightScreenCaptureAccess() ? .granted : .denied
        if sr != screenRecording { screenRecording = sr }

        // Local network stays at whatever noteLocalNetworkActivity() last
        // set it to. We only downgrade it to .unknown on first launch.
    }

    // MARK: - Requesting access

    /// Trigger the Accessibility prompt. The user has to drag Sidekick into
    /// the list in System Settings; there's no in-process grant.
    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Trigger the Screen Recording prompt. Returns the (possibly stale)
    /// answer; the user has to toggle Sidekick on in System Settings and
    /// re-launch the app for the grant to actually take effect.
    public func requestScreenRecording() {
        // The macOS API: fires the prompt + returns whether access is
        // already granted. We ignore the bool — refresh() will pick up
        // the change on the next poll.
        _ = CGRequestScreenCaptureAccess()
    }

    /// Open System Settings to the Local Network pane. There's no
    /// programmatic prompt — the OS shows it automatically the first
    /// time the app browses, but if the user dismissed it they need
    /// to flip the switch by hand.
    public func openLocalNetworkSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
        NSWorkspace.shared.open(url)
    }

    public func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    public func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
