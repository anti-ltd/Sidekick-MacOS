import Foundation
import Network

/// Length-prefixed JSON framing on top of an `NWConnection`. Used by both
/// `BonjourSignaling` (client side) and `BonjourSignalingHost` (host
/// side) — they share the framing rules so a single end can stay on
/// one wire format.
///
/// Frame layout: 4-byte big-endian length, then that many UTF-8 bytes
/// of JSON-encoded `SignalingFrame`. No magic header — the connection
/// is already typed by the Bonjour service.
final class SignalingChannel: @unchecked Sendable {

    private let connection: NWConnection
    private let inboundCont: AsyncStream<SignalingFrame>.Continuation
    let inbound: AsyncStream<SignalingFrame>

    init(connection: NWConnection) {
        self.connection = connection
        var cont: AsyncStream<SignalingFrame>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        self.inboundCont = cont
    }

    /// Bring the connection up and start the read loop. Suspends until the
    /// connection reaches `.ready`; throws on any non-ready terminal state.
    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let err): cont.resume(throwing: err)
                case .cancelled: cont.resume(throwing: TransportError.signalingFailed("cancelled"))
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        Task.detached { [weak self] in await self?.readLoop() }
    }

    /// Send a single frame. Errors are propagated through the throwing API.
    func send(_ frame: SignalingFrame) async throws {
        let payload = try JSONEncoder().encode(frame)
        var header = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        header.append(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: header, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    func close() {
        connection.cancel()
        inboundCont.finish()
    }

    // MARK: - Internal read loop

    private func readLoop() async {
        while true {
            guard let header = await receive(exactly: 4) else { break }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            // Defensive cap — 1 MB is plenty for SDP/ICE; bigger means
            // something is wrong on the wire.
            guard length > 0, length < 1_000_000 else { break }
            guard let body = await receive(exactly: Int(length)) else { break }
            guard let frame = try? JSONDecoder().decode(SignalingFrame.self, from: body) else { continue }
            inboundCont.yield(frame)
            if frame.kind == .bye { break }
        }
        inboundCont.finish()
    }

    private func receive(exactly count: Int) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, err in
                if err != nil { cont.resume(returning: nil); return }
                cont.resume(returning: data)
            }
        }
    }
}
