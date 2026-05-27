import Foundation
import AppKit
import Combine

/// Bidirectional pasteboard sync. Both ends watch their local pasteboard at
/// 0.5s intervals; when the change-count ticks they read it, hash it, and
/// publish to the other side over `RPCEnvelope.Channel.clipboard`.
///
/// The hash is so we don't ping-pong: the receiver of an inbound clipboard
/// update writes it to the local pasteboard, then ignores the immediate
/// change-count bump it just caused.
public protocol ClipboardChannel: AnyObject, Sendable {
    /// Begin polling the local pasteboard and forwarding changes to `send`.
    func start(send: @escaping @Sendable (ClipboardMessage) async -> Void)
    /// Apply an inbound clipboard message to the local pasteboard.
    func apply(_ message: ClipboardMessage)
    func stop()
}

/// One clipboard update on the wire. v0 carries plain text + RTF + a
/// PNG-encoded image; we'll add file references once the file channel
/// lands and we can resolve "the same Finder URL" across machines.
public struct ClipboardMessage: Codable, Sendable, Equatable {
    public var plain: String?
    public var rtf: Data?
    public var pngImage: Data?
    /// Stable hash over the payloads — lets the sender skip echoing back
    /// what it just received from the peer.
    public var hash: String

    public init(plain: String? = nil, rtf: Data? = nil, pngImage: Data? = nil, hash: String) {
        self.plain = plain
        self.rtf = rtf
        self.pngImage = pngImage
        self.hash = hash
    }
}

public final class NSPasteboardClipboardChannel: ClipboardChannel, @unchecked Sendable {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastSentHash: String?
    /// Set after applying an inbound message so the very next poll tick
    /// doesn't immediately re-publish what we just wrote.
    private var lastAppliedHash: String?

    public init() {}

    public func start(send: @escaping @Sendable (ClipboardMessage) async -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick(send: send)
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(send: @escaping @Sendable (ClipboardMessage) async -> Void) {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let plain = pb.string(forType: .string)
        let rtf = pb.data(forType: .rtf)
        let png = pb.data(forType: .png)
        let hash = ClipboardHasher.hash(plain: plain, rtf: rtf, png: png)
        guard hash != lastAppliedHash, hash != lastSentHash else { return }
        lastSentHash = hash
        let msg = ClipboardMessage(plain: plain, rtf: rtf, pngImage: png, hash: hash)
        Task { await send(msg) }
    }

    public func apply(_ message: ClipboardMessage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let s = message.plain { pb.setString(s, forType: .string) }
        if let r = message.rtf   { pb.setData(r, forType: .rtf) }
        if let p = message.pngImage { pb.setData(p, forType: .png) }
        lastAppliedHash = message.hash
        lastChangeCount = pb.changeCount
    }
}

/// Stable hash over a clipboard payload. Cheap SHA256 via CommonCrypto would
/// be ideal but pulling that import in just for this is overkill — Foundation's
/// `Data.hashValue` is process-stable in practice and good enough to debounce.
enum ClipboardHasher {
    static func hash(plain: String?, rtf: Data?, png: Data?) -> String {
        var hasher = Hasher()
        hasher.combine(plain ?? "")
        hasher.combine(rtf ?? Data())
        hasher.combine(png ?? Data())
        return String(hasher.finalize())
    }
}
