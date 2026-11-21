import Dispatch
import Foundation
import XCTest
@testable import SocketIO

/// Pin the distinction between connection failures, runtime diagnostics and
/// inactive namespaces without opening a network connection or sleeping.
final class SocketManagerEngineErrorTest: XCTestCase {
    func testEstablishedSocketReceivesRuntimeErrorNotConnectError() {
        assertErrorRouting(active: true, status: .connected, expected: .error)
    }

    func testOpeningSocketReceivesConnectErrorNotRuntimeError() {
        assertErrorRouting(active: true, status: .connecting, expected: .connectError)
    }

    func testInactiveSocketsIgnoreEngineErrorsRegardlessOfStatus() {
        for status: SocketIOStatus in [.notConnected, .connecting, .connected, .disconnected] {
            assertErrorRouting(active: false, status: status, expected: nil)
        }
    }

    private func assertErrorRouting(active: Bool, status: SocketIOStatus,
                                    expected: SocketClientEvent?,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let queue = DispatchQueue(label: "SocketManagerEngineErrorTest.handle")
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                    config: [.log(false), .reconnects(false), .handleQueue(queue)])
        let reason = "NSPOSIXErrorDomain/57: Socket is not connected"
        var events = [String]()
        var reasons = [String]()

        queue.sync {
            let socket = manager.defaultSocket
            socket.setTestStatus(status)
            socket.setTestActive(active)
            socket.on(clientEvent: .error) { data, _ in
                events.append(SocketClientEvent.error.rawValue)
                reasons.append(data.first as? String ?? "")
            }
            socket.on(clientEvent: .connectError) { data, _ in
                events.append(SocketClientEvent.connectError.rawValue)
                reasons.append(data.first as? String ?? "")
            }
            manager.engineDidError(reason: reason)
        }
        // engineDidError enqueues its delivery on this serial queue. This
        // barrier runs after it, so absence assertions do not rely on a delay.
        queue.sync {
            XCTAssertEqual(events, expected.map { [$0.rawValue] } ?? [], file: file, line: line)
            XCTAssertEqual(reasons, expected == nil ? [] : [reason], file: file, line: line)
            manager.defaultSocket.removeAllHandlers()
        }
    }
}
