//
//  OnPublisher.swift
//  Observable
//
//  Created by Zahid on 28/12/2020.
//

import Foundation
import Combine

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public struct OnPublisher: Publisher {

    public typealias Output = OnSocketData
    public typealias Failure = Never

    let socket: SocketIOClient
    let controlEvent: String

    init(socket: SocketIOClient, event: String) {
        self.socket = socket
        self.controlEvent = event
    }
    
    
    public func receive<S>(subscriber: S) where S : Subscriber, S.Failure == OnPublisher.Failure, S.Input == OnPublisher.Output {
        let subscription = OnSubscription(subscriber: subscriber, socket: socket, event: controlEvent)
        subscriber.receive(subscription: subscription)
    }
}
