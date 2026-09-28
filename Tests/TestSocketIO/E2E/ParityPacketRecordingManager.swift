import Foundation
@testable import SocketIO

/// Records the real engine's packet creation boundary, as upstream packetCreate
/// does. I/O still runs through SocketEngine and the actual localhost server.
final class ParityPacketRecordingManager: SocketManager {
    override func connect() {
        if engine == nil {
            engine = ParityPacketRecordingEngine(client: self, url: socketURL, config: config)
        }
        super.connect()
    }

    var createdPackets: [String] {
        (engine as? ParityPacketRecordingEngine)?.createdPackets ?? []
    }
}

private final class ParityPacketRecordingEngine: SocketEngine {
    private let recordLock = NSLock()
    private var packets = [String]()

    var createdPackets: [String] {
        recordLock.lock()
        defer { recordLock.unlock() }
        return packets
    }

    override func write(_ message: String, withType type: SocketEnginePacketType,
                        withData data: [Data], completion: (() -> ())? = nil) {
        if type == .message {
            recordLock.lock()
            // Native root CONNECT/DISCONNECT spell the namespace explicitly. Both
            // encodings decode to exactly the same Socket.IO packet.
            packets.append(["0/,": "0", "1/,": "1"][message] ?? message)
            recordLock.unlock()
        }
        super.write(message, withType: type, withData: data, completion: completion)
    }
}
