import XCTest
@testable import SidekickCore

/// Round-trip the RPC envelope + a couple of channel payloads. Catches
/// silly regressions in the Codable shapes whenever we change them.
final class RPCTests: XCTestCase {
    func testInputEventRoundTrip() throws {
        let event = InputEvent.mouseDown(x: 0.5, y: 0.25, button: .left)
        let envelope = try RPCEnvelope.event(.input, event)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RPCEnvelope.self, from: data)
        XCTAssertEqual(decoded.channel, .input)
        let payload = try decoded.decode(InputEvent.self)
        XCTAssertEqual(payload, event)
    }

    func testClipboardRoundTrip() throws {
        let msg = ClipboardMessage(plain: "hello couch", hash: "abc")
        let envelope = try RPCEnvelope.event(.clipboard, msg)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RPCEnvelope.self, from: data)
        let back = try decoded.decode(ClipboardMessage.self)
        XCTAssertEqual(back, msg)
    }

    func testLoopbackTransport() async throws {
        let (a, b) = LoopbackTransport.pair()
        let payload = Data("ping".utf8)
        Task { try await a.send(payload) }
        var iterator = b.incoming.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, payload)
    }
}
