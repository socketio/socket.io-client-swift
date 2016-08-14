//
//  SocketExtensions.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 7/1/2016.
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

enum JSONError : ErrorType {
    case notArray
    case notNSDictionary
}

extension Array where Element: AnyObject {
    func toJSON() throws -> NSData {
        return try NSJSONSerialization.dataWithJSONObject(self as NSArray, options: NSJSONWritingOptions(rawValue: 0))
    }
}

extension NSCharacterSet {
    static var allowedURLCharacterSet: NSCharacterSet {
        return NSCharacterSet(charactersInString: "!*'();:@&=+$,/?%#[]\" {}").invertedSet
    }
}

extension NSDictionary {
    private static func keyValueToSocketIOClientOption(key: String, value: AnyObject) -> SocketIOClientOption? {
        switch (key, value) {
        case let ("connectParams", params as [String: AnyObject]):
            return .ConnectParams(params)
        case let ("cookies", cookies as [NSHTTPCookie]):
            return .Cookies(cookies)
        case let ("doubleEncodeUTF8", encode as Bool):
            return .DoubleEncodeUTF8(encode)
        case let ("extraHeaders", headers as [String: String]):
            return .ExtraHeaders(headers)
        case let ("forceNew", force as Bool):
            return .ForceNew(force)
        case let ("forcePolling", force as Bool):
            return .ForcePolling(force)
        case let ("forceWebsockets", force as Bool):
            return .ForceWebsockets(force)
        case let ("handleQueue", queue as dispatch_queue_t):
            return .HandleQueue(queue)
        case let ("log", log as Bool):
            return .Log(log)
        case let ("logger", logger as SocketLogger):
            return .Logger(logger)
        case let ("nsp", nsp as String):
            return .Nsp(nsp)
        case let ("path", path as String):
            return .Path(path)
        case let ("reconnects", reconnects as Bool):
            return .Reconnects(reconnects)
        case let ("reconnectAttempts", attempts as Int):
            return .ReconnectAttempts(attempts)
        case let ("reconnectWait", wait as Int):
            return .ReconnectWait(wait)
        case let ("secure", secure as Bool):
            return .Secure(secure)
        case let ("security", security as SSLSecurity):
            return .Security(security)
        case let ("selfSigned", selfSigned as Bool):
            return .SelfSigned(selfSigned)
        case let ("sessionDelegate", delegate as NSURLSessionDelegate):
            return .SessionDelegate(delegate)
        case let ("voipEnabled", enable as Bool):
            return .VoipEnabled(enable)
        default:
            return nil
        }
    }
    
    func toSocketConfiguration() -> SocketIOClientConfiguration {
        var options = [] as SocketIOClientConfiguration
        
        for (rawKey, value) in self {
            if let key = rawKey as? String, opt = NSDictionary.keyValueToSocketIOClientOption(key, value: value) {
                options.insert(opt)
            }
        }
        
        return options
    }
}

extension String {
    func toArray() throws -> [AnyObject] {
        guard let stringData = dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false) else { return [] }
        guard let array = try NSJSONSerialization.JSONObjectWithData(stringData, options: .MutableContainers) as? [AnyObject] else {
             throw JSONError.notArray
        }
        
        return array
    }
    
    func toNSDictionary() throws -> NSDictionary {
        guard let binData = dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false) else { return [:] }
        guard let json = try NSJSONSerialization.JSONObjectWithData(binData, options: .AllowFragments) as? NSDictionary else {
            throw JSONError.notNSDictionary
        }
        
        return json
    }
    
    func urlEncode() -> String? {
        return stringByAddingPercentEncodingWithAllowedCharacters(.allowedURLCharacterSet)
    }
}
