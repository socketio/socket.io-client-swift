import Foundation
import XCTest
@testable import SocketIO

final class SocketWebSocketConnectionStateTest: XCTestCase {
    func testForeignSessionDelegateEventsCannotChangeConnectionState() {
        let queue = DispatchQueue(label: "connection.foreign-session")
        let connection = URLSessionWebSocketConnection(
            request: URLRequest(url: URL(string: "ws://localhost")!), queue: queue,
            configuration: .ephemeral, maximumMessageSize: 1024)
        let proxy = WebSocketSessionDelegateProxy(owner: connection, tlsConfiguration: .systemDefault,
                                                  forwardingDelegate: nil)
        let foreignSession = URLSession(configuration: .ephemeral)
        defer { foreignSession.invalidateAndCancel() }
        let task = foreignSession.webSocketTask(with: URL(string: "ws://localhost")!)
        queue.sync { connection.onEvent = { _ in XCTFail("Accepted a foreign session event") } }
        proxy.urlSession(foreignSession, webSocketTask: task, didOpenWithProtocol: nil)
        proxy.urlSession(foreignSession, webSocketTask: task, didCloseWith: .normalClosure, reason: Data([1]))
        proxy.urlSession(foreignSession, task: task, didCompleteWithError: URLError(.cancelled))
        proxy.urlSession(foreignSession, didBecomeInvalidWithError: URLError(.cancelled))
        queue.sync {
            XCTAssertNil(connection.closeDetails.code)
            XCTAssertNil(connection.closeDetails.reason)
            connection.cancel()
        }
    }

    func testOperationsWithoutSessionFailOnceAndCancellationRemainsSafe() {
        let queue = DispatchQueue(label: "connection.states")
        let connection = URLSessionWebSocketConnection(
            request: URLRequest(url: URL(string: "ws://localhost")!), queue: queue,
            configuration: .ephemeral, maximumMessageSize: 1024)
        queue.sync {
            var sendCalls = 0
            var receiveCalls = 0
            connection.send(.binary(Data())) { error in
                guard case EngineWebSocketError.notOpen? = error as? EngineWebSocketError else {
                    return XCTFail("Expected notOpen, got \(String(describing: error))")
                }
                sendCalls += 1
            }
            connection.receive { result in
                guard case .failure(let error) = result else { return XCTFail("Unstarted receive succeeded") }
                guard case EngineWebSocketError.notOpen? = error as? EngineWebSocketError else {
                    return XCTFail("Expected notOpen, got \(String(describing: error))")
                }
                receiveCalls += 1
            }
            XCTAssertEqual(sendCalls, 1)
            XCTAssertEqual(receiveCalls, 1)
            XCTAssertNil(connection.closeDetails.code)
            XCTAssertNil(connection.closeDetails.reason)
            connection.close(code: -1, reason: nil)
            connection.cancel()
            connection.cancel()
            XCTAssertNil(connection.closeDetails.code)
        }
    }
}
