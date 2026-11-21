import XCTest
@testable import SocketIO

private extension SocketPacket {
    init(type: PacketType, nsp: String, placeholders: Int = 0, id: Int = -1, data: [Any]) {
        self.init(type: type, data: data, id: id, nsp: nsp, placeholders: placeholders)
    }
}

/// Unit-level scenarios ported one-to-one from the JavaScript client's own
/// test suite (`socket.io/packages/socket.io-client/test`, v4.8.3) that need
/// no server: packets are injected directly via `handlePacket`, the way
/// `SocketStateRecoveryTest` does.
final class JSParityUnitTest: XCTestCase {
    // MARK: connection.ts — "should emit a connect_error event when reaching a Socket.IO server in v2.x"

    /// The JS contract: on a v3 manager, a CONNECT packet WITHOUT a payload
    /// (no "sid") means the server speaks v2, so the client fires
    /// `connect_error` instead of `connect`. Written exactly as the JS
    /// contract says; whether this client honours it is for CI to decide
    /// (see report).
    func testConnectPacketWithoutPayloadFiresConnectError() {
        let manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false)])
        let socket = manager.defaultSocket
        socket.setTestStatus(.connecting)

        let gotError = expectation(description: ".connectError fired")
        gotError.assertForOverFulfill = false
        var errorMessage: String?
        socket.on(clientEvent: .connectError) { data, _ in
            errorMessage = data.first as? String
            gotError.fulfill()
        }

        let gotConnect = expectation(description: ".connect must not fire")
        gotConnect.isInverted = true
        socket.on(clientEvent: .connect) { _, _ in gotConnect.fulfill() }

        socket.handlePacket(SocketPacket(type: .connect, nsp: "/", placeholders: 0, id: -1, data: []))

        wait(for: [gotError, gotConnect], timeout: 1)
        XCTAssertEqual(errorMessage, SocketIOClient.v2ServerConnectErrorMessage)
        XCTAssertNotEqual(socket.status, .connected)
    }

    /// The v2 protocol carries no sid, so a bare CONNECT on a `.two` manager
    /// is a normal connect, not a version-mismatch error.

}
