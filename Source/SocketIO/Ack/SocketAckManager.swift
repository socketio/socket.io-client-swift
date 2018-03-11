//
//  SocketAckManager.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 4/3/15.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Dispatch
import Foundation

/// The status of an ack.
public enum SocketAckStatus : String {
    // MARK: Cases

    /// The ack timed out.
    case noAck = "NO ACK"
}

private struct SocketAck : Hashable {
    let ack: Int
    var callback: AckCallback!
    var hashValue: Int {
        return ack.hashValue
    }

    init(ack: Int) {
        self.ack = ack
    }

    init(ack: Int, callback: @escaping AckCallback) {
        self.ack = ack
        self.callback = callback
    }

    fileprivate static func <(lhs: SocketAck, rhs: SocketAck) -> Bool {
        return lhs.ack < rhs.ack
    }

    fileprivate static func ==(lhs: SocketAck, rhs: SocketAck) -> Bool {
        return lhs.ack == rhs.ack
    }
}

class SocketAckManager {
    private var acks = Set<SocketAck>(minimumCapacity: 1)

    func addAck(_ ack: Int, callback: @escaping AckCallback) {
        acks.insert(SocketAck(ack: ack, callback: callback))
    }

    /// Should be called on handle queue
    func executeAck(_ ack: Int, with items: [Any]) {
        acks.remove(SocketAck(ack: ack))?.callback(items)
    }

    /// Should be called on handle queue
    func timeoutAck(_ ack: Int) {
       acks.remove(SocketAck(ack: ack))?.callback?([SocketAckStatus.noAck.rawValue])
    }
}
