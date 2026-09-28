import Foundation

/// Native WebSocket resource limits. These are independent of the server's
/// Engine.IO `maxPayload`, which bounds HTTP polling POSTs only.
public struct SocketWebSocketOptions {
    public var maximumMessageSize: Int
    public var maximumPendingBytes: Int
    public var maximumPendingBatches: Int
    public var maximumPendingMessages: Int

    public init(maximumMessageSize: Int = 16 * 1024 * 1024,
                maximumPendingBytes: Int = 16 * 1024 * 1024,
                maximumPendingBatches: Int = 1024,
                maximumPendingMessages: Int = 4096) {
        self.maximumMessageSize = maximumMessageSize
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumPendingBatches = maximumPendingBatches
        self.maximumPendingMessages = maximumPendingMessages
    }

    internal var validationError: String? {
        guard maximumMessageSize > 0, maximumPendingBytes > 0,
              maximumPendingBatches > 0, maximumPendingMessages > 0 else {
            return "all webSocketOptions limits must be greater than zero"
        }
        return nil
    }
}
