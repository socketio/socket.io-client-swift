import Foundation

/// Internal transport contract. All methods, properties and callbacks are confined
/// to the serial engine queue supplied at construction. An open event only means
/// the WebSocket handshake succeeded, NOT that Engine.IO has received its open packet.
internal protocol EngineWebSocketTransport: AnyObject {
    var onEvent: ((EngineWebSocketEvent) -> Void)? { get set }
    var isWritable: Bool { get }
    func connect()
    func sendBatch(_ messages: [EngineWebSocketMessage], completion: @escaping (Result<Void, Error>) -> Void)
    func close(code: Int, reason: Data?)
    func abort()
}

internal enum EngineWebSocketMessage: Equatable {
    case text(String)
    case binary(Data)

    var byteCount: Int {
        switch self {
        case .text(let text): return text.utf8.count
        case .binary(let data): return data.count
        }
    }
}

internal enum EngineWebSocketEvent {
    case opened(protocol: String?, headers: [String: String] = [:])
    case message(EngineWebSocketMessage)
    case closed(code: Int?, reason: Data?, error: Error?)
}

internal enum EngineWebSocketError: Error, LocalizedError {
    case notOpen
    case cancelled
    case closed
    case queueLimitExceeded
    case invalidCloseFrame
    case unsupportedMessage

    var errorDescription: String? {
        switch self {
        case .notOpen: return "The WebSocket transport is not open."
        case .cancelled: return "The WebSocket transport was cancelled."
        case .closed: return "The WebSocket transport was closed."
        case .queueLimitExceeded: return "The WebSocket send queue limit was exceeded."
        case .invalidCloseFrame: return "The WebSocket close code or reason is invalid."
        case .unsupportedMessage: return "The WebSocket received an unsupported message type."
        }
    }
}

/// A connection represents one concrete session/task pair, never a reconnect.
/// Callbacks may arrive on any queue, including after cancellation. The transport
/// marshals them onto engineQueue and validates both generation and identity.
internal protocol EngineWebSocketConnection: AnyObject {
    /// Snapshot before cancellation: a receive failure can precede the close delegate callback.
    var closeDetails: (code: Int?, reason: Data?) { get }
    var onEvent: ((EngineWebSocketEvent) -> Void)? { get set }
    func start()
    func send(_ message: EngineWebSocketMessage, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Result<EngineWebSocketMessage, Error>) -> Void)
    func close(code: Int, reason: Data?)
    func cancel()
}

extension EngineWebSocketConnection {
    var closeDetails: (code: Int?, reason: Data?) { (nil, nil) }
}
