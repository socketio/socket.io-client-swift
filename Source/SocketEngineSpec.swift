//
//  SocketEngineSpec.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/7/15.
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
//

import Foundation

@objc public protocol SocketEngineSpec {
    weak var client: SocketEngineClient? { get set }
    var closed: Bool { get }
    var connected: Bool { get }
    var connectParams: [String: AnyObject]? { get set }
    var doubleEncodeUTF8: Bool { get }
    var cookies: [HTTPCookie]? { get }
    var extraHeaders: [String: String]? { get }
    var fastUpgrade: Bool { get }
    var forcePolling: Bool { get }
    var forceWebsockets: Bool { get }
    var parseQueue: DispatchQueue! { get }
    var polling: Bool { get }
    var probing: Bool { get }
    var emitQueue: DispatchQueue! { get }
    var handleQueue: DispatchQueue! { get }
    var sid: String { get }
    var socketPath: String { get }
    var urlPolling: NSURL { get }
    var urlWebSocket: NSURL { get }
    var websocket: Bool { get }
    var ws: WebSocket? { get }
    
    init(client: SocketEngineClient, url: NSURL, options: NSDictionary?)
    
    func connect()
    func didError(error: String)
    func disconnect(reason: String)
    func doFastUpgrade()
    func flushWaitingForPostToWebSocket()
    func parseEngineData(data: NSData)
    func parseEngineMessage(message: String, fromPolling: Bool)
    func write(msg: String, withType type: SocketEnginePacketType, withData data: [NSData])
}

extension SocketEngineSpec {
    var urlPollingWithSid: NSURL {
        let com = NSURLComponents(url: urlPolling as URL, resolvingAgainstBaseURL: false)!
        com.percentEncodedQuery = com.percentEncodedQuery! + "&sid=\(sid.urlEncode()!)"
        
        return com.url!
    }
    
    var urlWebSocketWithSid: NSURL {
        let com = NSURLComponents(url: urlWebSocket as URL, resolvingAgainstBaseURL: false)!
        com.percentEncodedQuery = com.percentEncodedQuery! + (sid == "" ? "" : "&sid=\(sid.urlEncode()!)")
        
        return com.url!
    }
    
    func createBinaryDataForSend(data: NSData) -> Either<NSData, String> {
        if websocket {
            var byteArray = [UInt8](repeating: 0x4, count: 1)//(count: 1, repeatedValue: 0x4) swift3
            let mutData = NSMutableData(bytes: &byteArray, length: 1)
            
            mutData.append(data as Data)
            
            return .Left(mutData)
        } else {
            let str = "b4" + data.base64EncodedString(NSData.Base64EncodingOptions(rawValue: 0))
            
            return .Right(str)
        }
    }
    
    func doubleEncodeUTF8(string: String) -> String {
        if let latin1 = string.data(using: String.Encoding.utf8),
            utf8 = NSString(data: latin1, encoding: String.Encoding.isoLatin1.rawValue) {
                return utf8 as String
        } else {
            return string
        }
    }
    
    func fixDoubleUTF8(string: String) -> String {
        if let utf8 = string.data(using: String.Encoding.isoLatin1),
            latin1 = NSString(data: utf8, encoding: String.Encoding.utf8.rawValue) {
                return latin1 as String
        } else {
            return string
        }
    }
    
    /// Send an engine message (4)
    func send(msg: String, withData datas: [NSData]) {
        write(msg: msg, withType: .Message, withData: datas)
    }
}
