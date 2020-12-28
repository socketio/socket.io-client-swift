//
//  OnSubscription.swift
//  Observable
//
//  Created by Zahid on 28/12/2020.
//

import Foundation
import Combine

public typealias OnSocketData = (data: [Any], ack: SocketAckEmitter)

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class OnSubscription<OnSubscriber: Subscriber>: Subscription where OnSubscriber.Input == OnSocketData {
    private var subscriber: OnSubscriber?
    private let socket: SocketIOClient
    var uuid: UUID?
    init(subscriber: OnSubscriber, socket: SocketIOClient, event: String) {
        self.subscriber = subscriber
        self.socket = socket
        uuid = socket.on(event) { (data, ack) in
           _ = subscriber.receive((data, ack))
        }
    }

    public func request(_ demand: Subscribers.Demand) { }

    public func cancel() {
        guard let ud = self.uuid else {
            return
        }
        socket.off(id: ud)
    }
}
