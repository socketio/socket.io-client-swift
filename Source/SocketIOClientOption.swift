//
//  SocketIOClientOption .swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/17/15.
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

protocol ClientOption: CustomStringConvertible, Hashable {
    func getSocketIOOptionValue() -> AnyObject?
}

public enum SocketIOClientOption: ClientOption {
    case ConnectParams([String: AnyObject])
    case Cookies([NSHTTPCookie])
    case ExtraHeaders([String: String])
    case ForceNew(Bool)
    case ForcePolling(Bool)
    case ForceWebsockets(Bool)
    case HandleQueue(dispatch_queue_t)
    case Log(Bool)
    case Logger(SocketLogger)
    case Nsp(String)
    case Path(String)
    case Reconnects(Bool)
    case ReconnectAttempts(Int)
    case ReconnectWait(Int)
    case Secure(Bool)
    case SelfSigned(Bool)
    case SessionDelegate(NSURLSessionDelegate)
    case VoipEnabled(Bool)
    
    public var description: String {
        if let label = Mirror(reflecting: self).children.first?.label {
            return String(label[label.startIndex]).lowercaseString + String(label.characters.dropFirst())
        } else {
            return ""
        }
    }
    
    public var hashValue: Int {
        return description.hashValue
    }
    
    static func keyValueToSocketIOClientOption(key: String, value: AnyObject) -> SocketIOClientOption? {
        switch (key, value) {
        case ("connectParams", let params as [String: AnyObject]):
            return .ConnectParams(params)
        case ("reconnects", let reconnects as Bool):
            return .Reconnects(reconnects)
        case ("reconnectAttempts", let attempts as Int):
            return .ReconnectAttempts(attempts)
        case ("reconnectWait", let wait as Int):
            return .ReconnectWait(wait)
        case ("forceNew", let force as Bool):
            return .ForceNew(force)
        case ("forcePolling", let force as Bool):
            return .ForcePolling(force)
        case ("forceWebsockets", let force as Bool):
            return .ForceWebsockets(force)
        case ("nsp", let nsp as String):
            return .Nsp(nsp)
        case ("cookies", let cookies as [NSHTTPCookie]):
            return .Cookies(cookies)
        case ("log", let log as Bool):
            return .Log(log)
        case ("logger", let logger as SocketLogger):
            return .Logger(logger)
        case ("sessionDelegate", let delegate as NSURLSessionDelegate):
            return .SessionDelegate(delegate)
        case ("path", let path as String):
            return .Path(path)
        case ("extraHeaders", let headers as [String: String]):
            return .ExtraHeaders(headers)
        case ("handleQueue", let queue as dispatch_queue_t):
            return .HandleQueue(queue)
        case ("voipEnabled", let enable as Bool):
            return .VoipEnabled(enable)
        case ("secure", let secure as Bool):
            return .Secure(secure)
        case ("selfSigned", let selfSigned as Bool):
            return .SelfSigned(selfSigned)
        default:
            return nil
        }
    }
    
    func getSocketIOOptionValue() -> AnyObject? {
       return Mirror(reflecting: self).children.first?.value as? AnyObject
    }
}

public func ==(lhs: SocketIOClientOption, rhs: SocketIOClientOption) -> Bool {
    return lhs.description == rhs.description
}

extension Set where Element: ClientOption {
    mutating func insertIgnore(element: Element) {
        if !contains(element) {
            insert(element)
        }
    }
    
    static func NSDictionaryToSocketOptionsSet(dict: NSDictionary) -> Set<SocketIOClientOption> {
        var options = Set<SocketIOClientOption>()
        
        for (rawKey, value) in dict {
            if let key = rawKey as? String, opt = SocketIOClientOption.keyValueToSocketIOClientOption(key, value: value) {
                options.insertIgnore(opt)
            }
        }
        
        return options
    }
    
    func SocketOptionsSetToNSDictionary() -> NSDictionary {
        let options = NSMutableDictionary()
        
        for option in self {
            options[option.description] = option.getSocketIOOptionValue()
        }
        
        return options
    }
}
