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
        switch key {
        case "connectParams" where value is [String: AnyObject]:
            return .ConnectParams(value as! [String: AnyObject])
        case "reconnects" where value is Bool:
            return .Reconnects(value as! Bool)
        case "reconnectAttempts" where value is Int:
            return .ReconnectAttempts(value as! Int)
        case "reconnectWait" where value is Int:
            return .ReconnectWait(value as! Int)
        case "forcePolling" where value is Bool:
            return .ForcePolling(value as! Bool)
        case "forceWebsockets" where value is Bool:
            return .ForceWebsockets(value as! Bool)
        case "nsp" where value is String:
            return .Nsp(value as! String)
        case "cookies" where value is [NSHTTPCookie]:
            return .Cookies(value as! [NSHTTPCookie])
        case "log" where value is Bool:
            return .Log(value as! Bool)
        case "logger" where value is SocketLogger:
            return .Logger(value as! SocketLogger)
        case "sessionDelegate" where value is NSURLSessionDelegate:
            return .SessionDelegate(value as! NSURLSessionDelegate)
        case "path" where value is String:
            return .Path(value as! String)
        case "extraHeaders" where value is [String: String]:
            return .ExtraHeaders(value as! [String: String])
        case "handleQueue" where value is dispatch_queue_t:
            return .HandleQueue(value as! dispatch_queue_t)
        case "voipEnabled" where value is Bool:
            return .VoipEnabled(value as! Bool)
        case "secure" where value is Bool:
            return .Secure(value as! Bool)
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
        let (insertType, _) = Mirror(reflecting: element).children.first!
        for item in self {
            let (name, _) = Mirror(reflecting: item).children.first!
            if insertType == name {
                return
            }
        }
        
        self.insert(element)
    }
    
    static func NSDictionaryToSocketOptionsSet(dict: NSDictionary) -> Set<SocketIOClientOption> {
        var options = Set<SocketIOClientOption>()
        
        for (rawKey, value) in dict {
            if let key = rawKey as? String, opt = SocketIOClientOption.keyValueToSocketIOClientOption(key, value: value) {
                options.insert(opt)
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
