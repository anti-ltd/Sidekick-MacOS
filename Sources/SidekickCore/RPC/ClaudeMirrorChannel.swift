import Foundation
import AppKit
import ApplicationServices

/// Mirror the focused Claude Code transcript on the host onto the iOS device,
/// so the user can read it from the couch without squinting at the TV.
///
/// Strategy for v1: walk the focused Terminal / iTerm / Ghostty / VS Code
/// integrated-terminal window via Accessibility, read the visible text
/// (`AXValue` on the text-area descendant), publish on a 0.5s tick. That's
/// already enough to read responses comfortably on a phone.
///
/// v2 will speak to Claude Code directly via its log file (
/// `~/.claude/projects/*/.../transcript.jsonl`) so we get prompt vs.
/// response structure and can render code blocks properly.
public enum ClaudeMirrorChannel {
    public struct Message: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case snapshot     // host → client: full visible text
            case requestFocus // client → host: bring Claude window to front
            case sendInput    // client → host: type into the prompt
        }
        public var kind: Kind
        public var text: String?
    }
}

@MainActor
public final class ClaudeMirrorHostAdapter {
    public typealias Send = @MainActor (ClaudeMirrorChannel.Message) async -> Void

    private var timer: Timer?
    private var lastSent: String?

    public init() {}

    public func start(send: @escaping Send) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.tick(send: send) }
        }
    }

    public func stop() {
        timer?.invalidate(); timer = nil
    }

    private func tick(send: Send) async {
        guard let text = visibleTranscriptText() else { return }
        if text == lastSent { return }
        lastSent = text
        await send(.init(kind: .snapshot, text: text))
    }

    public func apply(_ message: ClaudeMirrorChannel.Message) {
        switch message.kind {
        case .requestFocus:
            // Best-effort: just activate the most recently-frontmost
            // terminal-class app. Refine once we have per-app heuristics.
            for app in NSWorkspace.shared.runningApplications {
                if let bid = app.bundleIdentifier,
                   bid.contains("Terminal") || bid.contains("iTerm") ||
                   bid.contains("ghostty")  || bid.contains("Code") {
                    app.activate()
                    return
                }
            }
        case .sendInput:
            if let t = message.text {
                let injector = CGEventInjector()
                Task { await injector.apply(.insertText(t)) }
            }
        case .snapshot:
            break
        }
    }

    // MARK: - AX scraping

    private func visibleTranscriptText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window
        else { return nil }
        // Depth-first walk for the first AXTextArea / AXScrollArea with a
        // multi-line `AXValue`. Good enough for Terminal, iTerm and the
        // integrated terminal in VS Code.
        return findTextValue(in: window as! AXUIElement, depth: 0)
    }

    private func findTextValue(in element: AXUIElement, depth: Int) -> String? {
        if depth > 8 { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let s = value as? String, s.contains("\n"), s.count > 40 {
            return s
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let arr = children as? [AXUIElement] {
            for child in arr {
                if let found = findTextValue(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}
