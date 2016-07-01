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
    class var allowedURLCharacterSet: NSCharacterSet {
        return NSCharacterSet(charactersInString: "!*'();:@&=+$,/?%#[]\" {}").invertedSet
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
