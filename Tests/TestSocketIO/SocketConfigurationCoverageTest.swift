import Foundation
import XCTest
@testable import SocketIO

final class SocketConfigurationCoverageTest: XCTestCase {
    func testMutableCollectionSupportsIterationSubscriptsAndIndependentSlices() {
        var config: SocketIOClientConfiguration = []
        XCTAssertTrue(config.isEmpty)
        XCTAssertEqual(config.startIndex, config.endIndex)
        config = [.path("/a"), .log(false), .forceNew(false)]
        XCTAssertFalse(config.isEmpty)
        XCTAssertEqual(config.index(after: config.startIndex), 1)
        config[1] = .log(true)
        XCTAssertEqual(config[1].getSocketIOOptionValue() as? Bool, true)
        var slice = config[0..<2]
        slice[0] = .path("/detached")
        XCTAssertEqual(config[0].getSocketIOOptionValue() as? String, "/a")
        config[0..<2] = [.path("/b")]
        XCTAssertEqual(Array(config).map(\.description), ["path", "forceNew"])
        XCTAssertEqual(config.first?.getSocketIOOptionValue() as? String, "/b")
        XCTAssertEqual(config.endIndex, 2)
    }

    func testDictionaryBridgePreservesScalarAndObjectOptions() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "token", .value: "test"]))
        let values: [String: Any] = [
            "ackTimeout": 0.25, "retries": 3, "connectTimeout": 2.5,
            "autoConnect": false, "connectParams": ["q": "value"],
            "withCredentials": true, "forceBase64": true, "addTrailingSlash": false,
            "cookies": [cookie], "extraHeaders": ["X-Test": "value"], "forceNew": true,
            "tryAllTransports": true, "rememberUpgrade": true, "forcePolling": false,
            "forceWebsockets": true, "log": false, "path": "/custom",
            "reconnects": false, "reconnectAttempts": 7, "reconnectWait": 2,
            "reconnectWaitMax": 10, "randomizationFactor": 0.25, "secure": true,
            "timestampRequests": false, "timestampParam": "cache"
        ]
        let converted = values.toSocketConfiguration()
        XCTAssertEqual(converted.count, values.count)
        for option in converted {
            let expected = try XCTUnwrap(values[option.description] as? NSObject, option.description)
            let actual = try XCTUnwrap(option.getSocketIOOptionValue() as? NSObject, option.description)
            XCTAssertEqual(actual, expected, option.description)
        }
        let manager = SocketManager(socketURL: URL(string: "http://localhost")!,
                                    config: ["ackTimeout": 0.25, "retries": 3, "autoConnect": false])
        XCTAssertEqual(manager.ackTimeout, 0.25)
        XCTAssertEqual(manager.retries, 3)
        let empty = SocketManager(socketURL: URL(string: "http://localhost")!, config: nil as [String: Any]?)
        XCTAssertFalse(empty.autoConnect)
    }

    func testDictionaryBridgePreservesNativeOptionsAndTransportOrder() throws {
        let queue = DispatchQueue(label: "configuration.identity")
        let logger = DefaultSocketLogger()
        let delegate = NSObjectSessionDelegate()
        let parser = SocketParserOptions(maximumAttachments: 3)
        let limits = SocketBufferLimits(maximumSendBufferPackets: 4)
        let webSocket = SocketWebSocketOptions(maximumMessageSize: 1234)
        let values: [String: Any] = ["handleQueue": queue, "logger": logger,
            "sessionDelegate": delegate, "parserOptions": parser, "bufferLimits": limits,
            "webSocketOptions": webSocket, "security": SocketTLSConfiguration.systemDefault,
            "transports": ["websocket", "polling"]]
        let converted = values.toSocketConfiguration()
        XCTAssertEqual(converted.count, values.count)
        for option in converted {
            let value = option.getSocketIOOptionValue()
            switch option {
            case .handleQueue: XCTAssertTrue(value as? DispatchQueue === queue)
            case .logger: XCTAssertTrue(value as? DefaultSocketLogger === logger)
            case .sessionDelegate: XCTAssertTrue(value as? NSObjectSessionDelegate === delegate)
            case .parserOptions: XCTAssertEqual((value as? SocketParserOptions)?.maximumAttachments, 3)
            case .bufferLimits: XCTAssertEqual(value as? SocketBufferLimits, limits)
            case .webSocketOptions: XCTAssertEqual((value as? SocketWebSocketOptions)?.maximumMessageSize, 1234)
            case .transports: XCTAssertEqual(value as? [SocketTransport], [.websocket, .polling])
            case .security:
                guard let policy = value as? SocketTLSConfiguration, case .systemDefault = policy else {
                    return XCTFail("TLS policy changed")
                }
            default: XCTFail("Unexpected option: \(option)")
            }
        }
    }

    func testMalformedNewOptionsFailClosedAndUnknownKeysStayIgnored() {
        for key in ["ackTimeout", "retries", "transports", "tryAllTransports", "rememberUpgrade", "bufferLimits"] {
            let config = [key: "wrong type"].toSocketConfiguration()
            XCTAssertEqual(config.count, 1)
            guard let option = config.first, case .invalidConfiguration(let reason) = option else { return XCTFail(key) }
            XCTAssertTrue(reason.contains(key))
            XCTAssertEqual(config.first?.getSocketIOOptionValue() as? String, reason)
        }
        let unsupported = ["transports": ["polling", "webtransport"]].toSocketConfiguration()
        guard let option = unsupported.first, case .invalidConfiguration = option else { return XCTFail("Unknown transport accepted") }
        XCTAssertTrue(["unknownApplicationOption": 123].toSocketConfiguration().isEmpty)
    }

    func testDefaultLoggerLazilyEvaluatesEnabledMessagesOnly() {
        let logger = DefaultSocketLogger()
        var evaluations = 0
        func message() -> String { evaluations += 1; return "coverage diagnostic" }
        logger.log(message(), type: "test")
        logger.error(message(), type: "test")
        XCTAssertEqual(evaluations, 0)
        logger.log = true
        logger.log(message(), type: "test")
        logger.error(message(), type: "test")
        XCTAssertEqual(evaluations, 2)
        XCTAssertTrue(SocketAckStatus.noAck == "NO ACK")
        XCTAssertFalse(SocketAckStatus.noAck == "different")
        XCTAssertEqual(SocketAnyEvent(event: "test", items: nil).description, "SocketAnyEvent: Event: test items: nil")
    }
}

private final class NSObjectSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {}
