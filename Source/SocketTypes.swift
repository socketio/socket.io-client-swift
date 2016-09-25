//
//  SocketTypes.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 4/8/15.
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

import Foundation

public protocol SocketData {}

extension Array : SocketData {}
extension Bool : SocketData {}
extension Dictionary : SocketData {}
extension Double : SocketData {}
extension Int : SocketData {}
extension NSArray : SocketData {}
extension Data : SocketData {}
extension NSData : SocketData {}
extension NSDictionary : SocketData {}
extension NSString : SocketData {}
extension NSNull : SocketData {}
extension String : SocketData {}

public typealias AckCallback = ([Any]) -> Void
public typealias NormalCallback = ([Any], SocketAckEmitter) -> Void

typealias JSON = [String: Any]
typealias Probe = (msg: String, type: SocketEnginePacketType, data: [Data])
typealias ProbeWaitQueue = [Probe]

enum Either<E, V> {
    case left(E)
    case right(V)
}
