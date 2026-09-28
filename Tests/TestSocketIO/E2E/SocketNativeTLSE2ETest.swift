import Foundation
import Security
import XCTest
@testable import SocketIO

final class SocketNativeTLSE2ETest: XCTestCase {
    private func roundTrip(forcePolling: Bool, clientAuth: Bool = false) throws {
        let server = try TestServerProcess.start(serverScript: "native-tls-server.mjs",
            extraEnvironment: ["NATIVE_TLS_DIR": try NativeTLSFixtures.directory().path,
                               "NATIVE_TLS_CLIENT_AUTH": clientAuth ? "1" : "0"])
        defer { server.stop() }
        var config: SocketIOClientConfiguration = [
            .forcePolling(forcePolling), .forceWebsockets(!forcePolling), .reconnects(false),
            .connectTimeout(5), .security(try NativeTLSFixtures.policy())
        ]
        if clientAuth { config.insert(.clientCertificate(try NativeTLSFixtures.clientCredential())) }
        let manager = SocketManager(socketURL: URL(string: "https://localhost:\(server.port)")!, config: config)
        defer { manager.disconnect() }
        let socket = manager.defaultSocket
        let echoed = expectation(description: "TLS multipart binary acknowledgement")
        socket.on(clientEvent: .connect) { _, _ in
            socket.emitWithAck("echoTwo", Data([1, 2, 3]), Data([4, 5, 6])).timingOut(after: 5) { values in
                XCTAssertEqual(values.count, 2)
                XCTAssertEqual(values.first as? Data, Data([1, 2, 3]))
                XCTAssertEqual(values.last as? Data, Data([4, 5, 6]))
                echoed.fulfill()
            }
        }
        socket.connect()
        wait(for: [echoed], timeout: 10)
    }

    func testClientCertificateAuthenticatesPolling() throws { try roundTrip(forcePolling: true, clientAuth: true) }
    func testClientCertificateAuthenticatesWebSocket() throws { try roundTrip(forcePolling: false, clientAuth: true) }

    func testNativeWebSocketTLSBinaryRoundTripWithPrivateCA() throws { try roundTrip(forcePolling: false) }

    /// The default transport path over TLS: HTTP long-polling handshake, then
    /// the WebSocket upgrade over `wss`. A device log showed every upgrade
    /// against a TLS server dying right after "Switching to WebSockets"; the
    /// plain-HTTP fixtures could not exercise that path.
    func testPollingToWebSocketUpgradeOverTLSStaysConnected() throws {
        try upgradeRoundTrip(clientAuth: false)
    }

    func testClientCertificateAuthenticatesPollingAndWebSocketUpgrade() throws {
        try upgradeRoundTrip(clientAuth: true)
    }

    private func upgradeRoundTrip(clientAuth: Bool) throws {
        let server = try TestServerProcess.start(serverScript: "native-tls-server.mjs",
            extraEnvironment: ["NATIVE_TLS_DIR": try NativeTLSFixtures.directory().path,
                               "NATIVE_TLS_CLIENT_AUTH": clientAuth ? "1" : "0"])
        defer { server.stop() }
        var config: SocketIOClientConfiguration = [
            .reconnects(false), .connectTimeout(5), .security(try NativeTLSFixtures.policy())
        ]
        if clientAuth { config.insert(.clientCertificate(try NativeTLSFixtures.clientCredential())) }
        let manager = SocketManager(socketURL: URL(string: "https://localhost:\(server.port)")!, config: config)
        defer { manager.disconnect() }
        let socket = manager.defaultSocket

        let connected = expectation(description: "connect over TLS")
        connected.assertForOverFulfill = false
        socket.on(clientEvent: .connect) { _, _ in connected.fulfill() }
        let upgraded = expectation(description: "wss upgrade")
        upgraded.assertForOverFulfill = false
        socket.on(clientEvent: .websocketUpgrade) { _, _ in upgraded.fulfill() }
        var disconnects = [String]()
        socket.on(clientEvent: .disconnect) { data, _ in disconnects.append(String(describing: data.first ?? "")) }
        var errors = [String]()
        socket.on(clientEvent: .error) { data, _ in errors.append(String(describing: data)) }

        socket.connect()
        wait(for: [connected, upgraded], timeout: 10)

        let settled = expectation(description: "upgrade packet sent, polling retired")
        DispatchQueue.main.socketAsyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(manager.engine?.polling, false, "the engine must be on the WebSocket now")
        XCTAssertEqual(manager.engine?.connected, true)

        let echoed = expectation(description: "binary acknowledgement over the upgraded wss transport")
        socket.emitWithAck("echoTwo", Data([1, 2, 3]), Data([4, 5, 6])).timingOut(after: 5) { values in
            XCTAssertEqual(values.first as? Data, Data([1, 2, 3]))
            XCTAssertEqual(values.last as? Data, Data([4, 5, 6]))
            echoed.fulfill()
        }
        wait(for: [echoed], timeout: 10)
        XCTAssertEqual(disconnects, [])
        XCTAssertEqual(errors, [])
    }
    func testPollingUsesTheSameTLSPolicyAndBinaryRoundTrip() throws { try roundTrip(forcePolling: true) }

    private func reject(host: String = "localhost", forcePolling: Bool = false, expired: Bool = false,
                        policy: SocketTLSConfiguration, clientAuth: Bool = false, credential: URLCredential? = nil,
                        delegate: URLSessionDelegate? = nil) throws {
        let server = try TestServerProcess.start(serverScript: expired ? "native-tls-expired.mjs" : "native-tls-server.mjs",
            extraEnvironment: ["NATIVE_TLS_DIR": try NativeTLSFixtures.directory().path,
                               "NATIVE_TLS_CLIENT_AUTH": clientAuth ? "1" : "0"])
        defer { server.stop() }
        var config: SocketIOClientConfiguration = [
            .forcePolling(forcePolling), .forceWebsockets(!forcePolling), .reconnects(false),
            .connectTimeout(5), .security(policy)
        ]
        if let delegate = delegate { config.insert(.sessionDelegate(delegate)) }
        if let credential { config.insert(.clientCertificate(credential)) }
        let manager = SocketManager(socketURL: URL(string: "https://\(host):\(server.port)")!, config: config)
        defer { manager.disconnect() }
        let socket = manager.defaultSocket
        let failed = expectation(description: "TLS must be rejected")
        failed.assertForOverFulfill = false
        socket.on(clientEvent: .connectError) { data, _ in
            XCTAssertNotEqual(data.first as? String, "timeout", "TLS must fail explicitly, not by connection timeout")
            failed.fulfill()
        }
        socket.on(clientEvent: .connect) { _, _ in XCTFail("Invalid TLS was accepted") }
        socket.connect()
        wait(for: [failed], timeout: 7)
        XCTAssertNotEqual(socket.status, .connected)
    }

    func testClientIdentityDoesNotBypassServerPinning() throws {
        try reject(policy: .customTrust(anchors: [NativeTLSFixtures.certificate("ca")],
                                        pins: [NativeTLSFixtures.certificate("expired")]),
                   clientAuth: true, credential: NativeTLSFixtures.clientCredential())
    }

    func testMutualTLSRejectsPollingWithoutClientIdentity() throws {
        try reject(forcePolling: true, policy: NativeTLSFixtures.policy(), clientAuth: true)
    }
    func testMutualTLSRejectsWebSocketWithoutClientIdentity() throws {
        try reject(policy: NativeTLSFixtures.policy(), clientAuth: true)
    }

    func testSystemTrustRejectsUntrustedFixtureCA() throws { try reject(policy: .systemDefault) }
    func testRealWebSocketRejectsWrongHostname() throws { try reject(host: "127.0.0.1", policy: NativeTLSFixtures.policy()) }
    func testRealWebSocketRejectsExpiredCertificate() throws { try reject(expired: true, policy: NativeTLSFixtures.policy(pinned: false)) }
    func testRealPollingRejectsWrongPin() throws {
        try reject(forcePolling: true, policy: .customTrust(anchors: [NativeTLSFixtures.certificate("ca")],
                                                          pins: [NativeTLSFixtures.certificate("expired")]))
    }
    func testExternalTrustAllDelegateCannotOverrideNativePins() throws {
        let delegate = AttemptedTrustBypassDelegate()
        try reject(policy: .customTrust(anchors: [NativeTLSFixtures.certificate("ca")],
                                        pins: [NativeTLSFixtures.certificate("expired")]), delegate: delegate)
        XCTAssertEqual(delegate.serverTrustCalls, 0)
    }
}

private final class AttemptedTrustBypassDelegate: NSObject, URLSessionDelegate {
    var serverTrustCalls = 0
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            serverTrustCalls += 1
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}
