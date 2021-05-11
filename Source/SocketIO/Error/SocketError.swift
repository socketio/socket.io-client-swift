//
//  SocketError.swift
//  Socket.IO-Client-Swift
//
//  Created by Jake Lavenberg on 5/10/21.
//

import Foundation
import Starscream

public enum SocketConnectionChangeReason {
    case socketError(_ error: SocketError)
    case calledDisconnectSocket
    case calledDisconnectManager
    case calledReconnect
    case gotDisconnectPacket
    case managerDeinit
    case addingNewEngine
    case engineOpen
    case engineCloseMessage(_ message: String)
    case websocketEngineCanceled
}

public enum SocketError: Error {
    case triedEmittingWhenNotConnected
    case autoReconnectFailed(_ attempt: Int)
    case urlSessionBecameInvalid(_ error: NSError?)
    case urlSessionError(_ error: Error?)
    case triedOpeningWhileConnected
//    case websocketError(_ error: WSError)
    case openPacketUnparseable
    case openPacketMissingSID
    case engineUnknownMessage(_ message: String)
    case engineErrorMessage(_ message: String)
    case nsError(_ error: NSError)
    case pingTimeout(_ actualTime: TimeInterval)
    case pongsMissed(_ pongsMissed: Int)
    case websocketEngineDisconnected(_ reason: String, _ code: Int)
    case websocketEngineError(_ error: Error?)
}
