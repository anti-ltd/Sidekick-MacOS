import Foundation
import CoreGraphics
import AppKit

/// Inject an `InputEvent` into the host Mac. Implementations bridge the
/// abstract event to the platform — CGEvent on macOS.
public protocol InputInjector: Sendable {
    /// `true` once macOS has granted the Accessibility permission. Drives
    /// the "Open System Settings" hint in host mode.
    var hasAccessibilityPermission: Bool { get }

    /// Trigger the macOS Accessibility prompt. Safe to call repeatedly; no-op
    /// once the grant is already in place.
    func requestPermission()

    /// Apply `event` to the host. Coordinates are in 0…1 fractions of the
    /// host's main display (see `InputEvent`).
    func apply(_ event: InputEvent) async
}

/// CGEvent-backed injector. Same pattern as Clonk — a stable signing identity
/// keeps the Accessibility grant alive across rebuilds, so the prompt only
/// appears once per machine.
public final class CGEventInjector: InputInjector, @unchecked Sendable {

    public init() {}

    public var hasAccessibilityPermission: Bool {
        // The non-prompting query — safe to poll from the UI.
        AXIsProcessTrusted()
    }

    public func requestPermission() {
        // Force the prompt. The user will be told to drag Sidekick into the
        // Accessibility list; nothing else we can do from in-process. Swift 6
        // flags kAXTrustedCheckOptionPrompt as shared mutable state — it's
        // a constant CFStringRef in practice, so an isolated read is safe.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    public func apply(_ event: InputEvent) async {
        guard let screen = NSScreen.main else { return }
        let size = screen.frame.size
        let source = CGEventSource(stateID: .hidSystemState)

        switch event {
        case .mouseMove(let x, let y):
            let p = CGPoint(x: x * size.width, y: y * size.height)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)

        case .mouseMoveRelative(let dx, let dy):
            // Read the current cursor location, add the scaled delta,
            // clamp to the active display rect, then post a move to the
            // resulting absolute position. We deliberately *don't* apply
            // any acceleration here — sensitivity scaling happens on
            // the iOS side so the user sees the same feel regardless
            // of host display size, and macOS' own pointer accel takes
            // care of the rest at the cursor level.
            let current = CGEvent(source: nil)?.location ?? .zero
            let target = CGPoint(
                x: min(max(current.x + dx * size.width, 0), size.width - 1),
                y: min(max(current.y + dy * size.height, 0), size.height - 1)
            )
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)

        case .mouseDown(let x, let y, let button):
            let p = CGPoint(x: x * size.width, y: y * size.height)
            CGEvent(mouseEventSource: source, mouseType: button.downType,
                    mouseCursorPosition: p, mouseButton: button.cg)?
                .post(tap: .cghidEventTap)

        case .mouseUp(let x, let y, let button):
            let p = CGPoint(x: x * size.width, y: y * size.height)
            CGEvent(mouseEventSource: source, mouseType: button.upType,
                    mouseCursorPosition: p, mouseButton: button.cg)?
                .post(tap: .cghidEventTap)

        case .click(let button):
            // Read where the cursor actually is so we click in place
            // rather than teleporting back to whatever absolute
            // position the client last sent.
            let current = CGEvent(source: nil)?.location ?? .zero
            CGEvent(mouseEventSource: source, mouseType: button.downType,
                    mouseCursorPosition: current, mouseButton: button.cg)?
                .post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: button.upType,
                    mouseCursorPosition: current, mouseButton: button.cg)?
                .post(tap: .cghidEventTap)

        case .scroll(let dx, let dy, _):
            // wheelCount: 2 = vertical + horizontal; values are line units.
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?
                .post(tap: .cghidEventTap)

        case .keyDown(let code, let mods, _):
            if let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
                e.flags = mods.cgFlags
                e.post(tap: .cghidEventTap)
            }

        case .keyUp(let code, let mods):
            if let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                e.flags = mods.cgFlags
                e.post(tap: .cghidEventTap)
            }

        case .insertText(let s):
            // Used by the iOS URL bar and "type from phone" paths. We send
            // the literal string as a CGEvent unicode payload — works for any
            // codepoint without us having to translate to a keyCode map.
            await insertText(s, source: source)
        }
    }

    private func insertText(_ s: String, source: CGEventSource?) async {
        for scalar in s.unicodeScalars {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            let chars = [UniChar(scalar.value & 0xFFFF)]
            chars.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

private extension InputEvent.MouseButton {
    var cg: CGMouseButton {
        switch self {
        case .left:   .left
        case .right:  .right
        case .middle: .center
        }
    }
    var downType: CGEventType {
        switch self {
        case .left:   .leftMouseDown
        case .right:  .rightMouseDown
        case .middle: .otherMouseDown
        }
    }
    var upType: CGEventType {
        switch self {
        case .left:   .leftMouseUp
        case .right:  .rightMouseUp
        case .middle: .otherMouseUp
        }
    }
}
