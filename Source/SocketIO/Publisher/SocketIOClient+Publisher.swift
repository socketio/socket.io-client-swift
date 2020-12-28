//
//  SocketIOClient+Publisher.swift
//  Socket.IO-Client-Swift
//
//  Created by Zahid on 28/12/2020.
//

import Foundation

@available(iOS 13.0, *)
public protocol SocketIOCombineCompatible {
    func publisher(on event: String) -> OnPublisher
    func publisher(clientEvent event: SocketClientEvent) -> OnPublisher
}

@available(iOS 13.0, *)
extension SocketIOClient: SocketIOCombineCompatible { }

@available(iOS 13.0, *)
extension SocketIOCombineCompatible where Self: SocketIOClient {
    public func publisher(on event: String) -> OnPublisher {
        return OnPublisher(socket: self, event: event)
    }
    
    public func publisher(clientEvent event: SocketClientEvent) -> OnPublisher {
        return OnPublisher(socket: self, event: event.rawValue)
    }
}
