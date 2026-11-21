//
//  SocketVolatileEmitter.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// JS-aligned volatile-emit chain. Drops the packet if the engine transport
/// is not writable. Does NOT fire `.error`, outgoing listeners, or buffer.
/// JS: `socket.io-client/lib/socket.ts emit()` body — gates on
/// `transport.writable`, not on `status`.
///
/// An acknowledgement is silent when a packet is dropped, unless `ackTimeout`
/// is configured, in which case it times out. Dropped untimed acknowledgements
/// are not retained. Volatile emissions always bypass the retry queue.
public struct SocketVolatileEmitter {
    let socket: SocketIOClient

    public func emit(_ event: String, _ items: SocketData..., completion: (() -> ())? = nil) {
        emit(event, with: items, completion: completion)
    }

    public func emit(_ event: String, with items: [SocketData], completion: (() -> ())? = nil) {
        do {
            let mapped = [event] + (try items.map { try $0.socketRepresentation() })
            socket.emitVolatile(mapped, completion: completion)
        } catch {
            DefaultSocketLogger.Logger.error(
                "Error creating socketRepresentation for volatile emit: \(event), \(items)",
                type: "SocketVolatileEmitter"
            )
            socket.handleClientEvent(.error, data: [event, items, error])
        }
    }

    /// Sends a volatile event with an error-first acknowledgement callback.
    public func emit(_ event: String, _ items: SocketData..., ack: @escaping (Error?, [Any]) -> Void) {
        emit(event, with: items, ack: ack)
    }

    public func emit(_ event: String, with items: [SocketData], ack: @escaping (Error?, [Any]) -> Void) {
        socket.emitVolatile(event: event, items: items, ack: ack)
    }
}
