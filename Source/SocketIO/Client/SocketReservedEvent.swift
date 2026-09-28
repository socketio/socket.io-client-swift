//
//  SocketReservedEvent.swift
//  Socket.IO-Client-Swift
//

import Foundation

/// Reserved event names that user code is forbidden from emitting.
/// The protocol forbids all six JS reserved names, even when the local
/// event-emitter implementation has no `newListener`/`removeListener` hooks.
internal enum SocketReservedEvent {
    static let names: Set<String> = [
        "connect", "connect_error", "disconnect", "disconnecting", "newListener", "removeListener"
    ]
}
