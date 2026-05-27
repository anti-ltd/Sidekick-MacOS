import Foundation
import CoreGraphics

/// Wire format for a single input event. Encoded as `Codable` JSON on the
/// RPC data channel — small enough we don't bother with a binary format yet.
///
/// Coordinates are always in *fractions of the host display* (0…1, top-left
/// origin), so an iPhone with a 1170pt screen and a 5120pt Mac display can
/// agree on a click target without the iPhone knowing the Mac's resolution.
public enum InputEvent: Codable, Sendable, Equatable {
    /// Absolute position in 0…1 fractions of the host's screen. Used for
    /// tap-to-click teleports and "snap cursor here" gestures.
    case mouseMove(x: Double, y: Double)
    /// Relative delta in 0…1 fractions of the host's screen. The host
    /// reads the current cursor position, adds (dx,dy)*screenSize, and
    /// posts the move. This is what makes the iOS pad feel like a real
    /// trackpad — lift finger, drop elsewhere, keep moving from the
    /// cursor's current spot rather than teleporting.
    case mouseMoveRelative(dx: Double, dy: Double)
    case mouseDown(x: Double, y: Double, button: MouseButton)
    case mouseUp(x: Double, y: Double, button: MouseButton)
    /// Atomic click at the host's *current* cursor position — no
    /// teleport. The trackpad uses this when a tap follows relative-
    /// move motion: the cursor is already where the user wants it.
    case click(button: MouseButton)
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    case keyDown(keyCode: UInt16, modifiers: ModifierFlags, characters: String?)
    case keyUp(keyCode: UInt16, modifiers: ModifierFlags)
    /// Drop a literal string into the focused field — used by the iOS URL
    /// bar and "type from phone keyboard" paths.
    case insertText(String)

    public enum MouseButton: String, Codable, Sendable {
        case left, right, middle
    }

    public enum ScrollPhase: String, Codable, Sendable {
        case began, changed, ended
    }

    public struct ModifierFlags: OptionSet, Codable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let shift   = ModifierFlags(rawValue: 1 << 0)
        public static let control = ModifierFlags(rawValue: 1 << 1)
        public static let option  = ModifierFlags(rawValue: 1 << 2)
        public static let command = ModifierFlags(rawValue: 1 << 3)
        public static let fn      = ModifierFlags(rawValue: 1 << 4)
        public static let caps    = ModifierFlags(rawValue: 1 << 5)
    }
}

public extension InputEvent.ModifierFlags {
    /// Bridge to CoreGraphics — applied to a `CGEvent` before posting so the
    /// receiving Mac sees a properly-stamped event.
    var cgFlags: CGEventFlags {
        var f = CGEventFlags()
        if contains(.shift)   { f.insert(.maskShift) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option)  { f.insert(.maskAlternate) }
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.fn)      { f.insert(.maskSecondaryFn) }
        if contains(.caps)    { f.insert(.maskAlphaShift) }
        return f
    }
}
