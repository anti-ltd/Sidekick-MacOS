import Foundation

/// Compile-time version constant, exposed in the Bonjour TXT record so a
/// browsing peer can decide whether it speaks the same protocol. Bump
/// `string` whenever the wire format changes.
public enum SidekickVersion {
    public static let string = "0.1"
}
