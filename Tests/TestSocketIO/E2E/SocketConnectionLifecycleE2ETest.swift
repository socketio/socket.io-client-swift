import Foundation
import XCTest
@testable import SocketIO

/// The callback is immutable; all connection state stays on its serial queue.
private final class ConnectionOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    let opened: (URLSession, URLSessionWebSocketTask) -> Void
    init(queue: DispatchQueue, opened: @escaping (URLSession, URLSessionWebSocketTask) -> Void) {
        self.queue = queue
        self.opened = opened
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        queue.socketAsync { self.opened(session, webSocketTask) }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

final class SocketConnectionLifecycleE2ETest: XCTestCase {
    func testNativeSessionInvalidationIsReportedWhileConnectionStillOwnsSession() throws {
        let server = try TestServerProcess.start()
        defer { server.stop() }
        let queue = DispatchQueue(label: "connection.invalidation.e2e")
        let invalidated = expectation(description: "native session invalidated")
        let delegate = ConnectionOpenDelegate(queue: queue) { session, _ in session.invalidateAndCancel() }
        let connection = URLSessionWebSocketConnection(
            request: URLRequest(url: URL(string: "ws://127.0.0.1:\(server.port)/socket.io/?EIO=4&transport=websocket")!),
            queue: queue, configuration: .ephemeral, maximumMessageSize: 1024, sessionDelegate: delegate)
        defer { queue.sync { connection.cancel() } }
        queue.sync {
            connection.onEvent = { event in
                // Task cancellation has a URL error; successful session invalidation
                // is the separate terminal callback with neither task code nor error.
                if case .closed(code: nil, reason: nil, error: nil) = event { invalidated.fulfill() }
            }
            connection.start()
            connection.start() // A repeated start must retain the same session/task.
        }
        wait(for: [invalidated], timeout: 10)
        withExtendedLifetime(delegate) {}
    }

    func testNativeCloseCallbackPreservesCloseCodeAndReason() throws {
        let server = try TestServerProcess.start()
        defer { server.stop() }
        let queue = DispatchQueue(label: "connection.close.e2e")
        let closed = expectation(description: "native close code")
        let reason = Data("finished".utf8)
        let delegate = ConnectionOpenDelegate(queue: queue) { _, task in
            task.cancel(with: .normalClosure, reason: reason)
        }
        let connection = URLSessionWebSocketConnection(
            request: URLRequest(url: URL(string: "ws://127.0.0.1:\(server.port)/socket.io/?EIO=4&transport=websocket")!),
            queue: queue, configuration: .ephemeral, maximumMessageSize: 1024, sessionDelegate: delegate)
        defer { queue.sync { connection.cancel() } }
        queue.sync {
            var observedClose = false
            connection.onEvent = { event in
                if case .closed(let code, let actualReason, _) = event, code == 1000, !observedClose {
                    observedClose = true
                    XCTAssertEqual(actualReason, reason)
                    closed.fulfill()
                }
            }
            connection.start()
        }
        wait(for: [closed], timeout: 10)
        withExtendedLifetime(delegate) {}
    }
}
