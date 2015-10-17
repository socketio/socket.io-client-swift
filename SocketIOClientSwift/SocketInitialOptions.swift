//
//  InitialOptions.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 17.10.15.
//
//

import Foundation

struct SocketInitialOptions {
    static let ConnectionParameter = "connectParams"
    static let Reconnects = "reconnects"
    static let ReconnectAttempts = "reconnectAttempts"
    static let ReconnectWait = "reconnectWait"
    static let ForcePolling = "forcePolling"
    static let ForceWebsockets = "forceWebsockets"
    static let Namespace = "nsp"
    static let Cookies = "cookies"
    static let Log = "log"
    static let CustomLogger = "logger"
    static let SessionDelegate = "sessionDelegate"
    static let Path = "path"
    static let ExtraHeaders = "extraHeaders"
    static let HandleQueue = "handleQueue"
}
