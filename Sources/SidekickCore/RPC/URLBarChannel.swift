import Foundation
import AppKit
import ApplicationServices

/// The headline iOS quality-of-life feature: instead of clicking the
/// browser's URL bar with a remote mouse and typing on a virtual keyboard,
/// the iOS app shows a native URL field. Editing it injects the text into
/// the focused browser tab's address bar on the host.
///
/// Approach: poll the frontmost app via the Accessibility API. If it's a
/// known browser (Safari, Chrome, Arc, Brave, Firefox, Orion…) read the
/// `kAXURLAttribute` from the focused window and publish it. Inbound
/// `setURL` messages set the same attribute back — the browser handles the
/// navigation as if the user had typed it.
public enum URLBarChannel {
    public struct Message: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case currentURL    // host → client: "here's what's in the URL bar"
            case setURL        // client → host: "navigate here"
            case focusBar      // client → host: "open quick-find / select all"
        }
        public var kind: Kind
        public var url: String?
        public var browserBundleID: String?
    }
}

/// Host-side adapter — owns the polling timer and the AX writes.
@MainActor
public final class URLBarHostAdapter {
    public typealias Send = @MainActor (URLBarChannel.Message) async -> Void

    private var timer: Timer?
    private var lastSent: String?

    public init() {}

    public func start(send: @escaping Send) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.tick(send: send) }
        }
    }

    public func stop() {
        timer?.invalidate(); timer = nil
    }

    private func tick(send: Send) async {
        guard let url = currentBrowserURL() else { return }
        if url == lastSent { return }
        lastSent = url
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        await send(.init(kind: .currentURL, url: url, browserBundleID: frontApp))
    }

    public func apply(_ message: URLBarChannel.Message) {
        switch message.kind {
        case .setURL:
            if let url = message.url { setBrowserURL(url) }
        case .focusBar:
            focusURLBar()
        case .currentURL:
            // Host-side ignores; this is a host→client direction.
            break
        }
    }

    // MARK: - Accessibility plumbing
    //
    // The standard pattern: take the frontmost app's AXUIElement, walk down
    // to the focused window, ask for `AXURL`. Browsers all expose it the
    // same way (it's how Universal Control / Safari extensions read URLs).
    // For unsupported apps we just emit nothing — the URL bar gracefully
    // hides in the iOS UI.

    private func currentBrowserURL() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window
        else { return nil }
        var url: CFTypeRef?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, "AXURL" as CFString, &url) == .success,
           let urlValue = url as? URL {
            return urlValue.absoluteString
        }
        return nil
    }

    private func setBrowserURL(_ url: String) {
        // Easiest portable approach: synthesise ⌘L (focus bar), then type
        // the URL, then Return. Works in every browser without needing app-
        // specific scripting. Slower than AX-writing the URL directly, but
        // doesn't need scripting entitlements for any individual browser.
        let injector = CGEventInjector()
        Task {
            await injector.apply(.keyDown(keyCode: 37 /* L */, modifiers: .command, characters: nil))
            await injector.apply(.keyUp(keyCode: 37, modifiers: .command))
            try? await Task.sleep(nanoseconds: 80_000_000)
            await injector.apply(.insertText(url))
            try? await Task.sleep(nanoseconds: 30_000_000)
            await injector.apply(.keyDown(keyCode: 36 /* Return */, modifiers: [], characters: nil))
            await injector.apply(.keyUp(keyCode: 36, modifiers: []))
        }
    }

    private func focusURLBar() {
        let injector = CGEventInjector()
        Task {
            await injector.apply(.keyDown(keyCode: 37, modifiers: .command, characters: nil))
            await injector.apply(.keyUp(keyCode: 37, modifiers: .command))
        }
    }
}
