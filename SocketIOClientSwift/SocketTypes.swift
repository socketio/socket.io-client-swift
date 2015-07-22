//
//  SocketTypes.swift
//  SocketIO-Swift
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

// @objc_block is undocumented, but is used because Swift assumes that all
// Objective-C blocks are copied, but Objective-C assumes that Swift will copy it.
// And the way things are done here, the bridging fails to copy the block in
// SocketAckMap#addAck
public typealias AckCallback = @objc_block (NSArray?) -> Void
public typealias AckEmitter = (AnyObject...) -> Void
public typealias NormalCallback = (NSArray?, AckEmitter?) -> Void
public typealias OnAckCallback = (timeoutAfter:UInt64, callback:AckCallback) -> Void
