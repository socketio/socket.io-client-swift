//
//  Event.swift
//  Socket.IO-Swift
//
//  Created by Erik Little on 1/18/15.
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

class Event {
    var args:AnyObject!
    lazy var currentPlace = 0
    lazy var datas = [NSData]()
    var event:String!
    var placeholders:Int!
    
    init(event:String, args:AnyObject?, placeholders:Int = 0) {
        self.event = event
        self.args = args?
        self.placeholders = placeholders
    }
    
    func addData(data:NSData) -> Bool {
        func checkDoEvent() -> Bool {
            if self.placeholders == self.currentPlace {
                return true
            } else {
                return false
            }
        }
        
        if checkDoEvent() {
            return true
        }
        
        self.datas.append(data)
        self.currentPlace++
        
        if checkDoEvent() {
            self.currentPlace = 0
            return true
        } else {
            return false
        }
    }
    
    class func createMessageForEvent(event:String, withArgs args:[AnyObject],
        hasBinary:Bool, withDatas datas:Int = 0) -> String {
            
            var message:String
            var jsonSendError:NSError?
            
            if !hasBinary {
                message = "42[\"\(event)\""
            } else {
                message = "45\(datas)-[\"\(event)\""
            }
            
            for arg in args {
                message += ","
                
                if arg is NSDictionary || arg is [AnyObject] {
                    let jsonSend = NSJSONSerialization.dataWithJSONObject(arg,
                        options: NSJSONWritingOptions(0), error: &jsonSendError)
                    let jsonString = NSString(data: jsonSend!, encoding: NSUTF8StringEncoding)
                    
                    message += jsonString!
                    continue
                }
                
                if arg is String {
                    message += "\"\(arg)\""
                    continue
                }
                
                message += "\(arg)"
            }
            
            return message + "]"
    }
    
    func fillInPlaceholders(_ args:AnyObject = true) -> AnyObject {
        if let dict = args as? NSDictionary {
            var newDict = [String: AnyObject]()
            
            for (key, value) in dict {
                newDict[key as String] = value
                
                // If the value is a string we need to check
                // if it is a placeholder for data
                if let value = value as? String {
                    if value == "~~\(self.currentPlace)" {
                        newDict[key as String] = self.datas.removeAtIndex(0)
                        self.currentPlace++
                    }
                }
            }
            
            return newDict
        } else if let string = args as? String {
            if string == "~~\(self.currentPlace)" {
                return self.datas.removeAtIndex(0)
            }
        } else if args is Bool {
            var returnArr = [AnyObject]()
            // We have multiple items
            // Do it live
            let argsAsArray = "[\(self.args)]"
            if let parsedArr = SocketIOClient.parseData(argsAsArray) as? NSArray {
                for item in parsedArr {
                    if let strItem = item as? String {
                        if strItem == "~~\(self.currentPlace)" {
                            returnArr.append(self.datas[self.currentPlace])
                            self.currentPlace++
                            continue
                        } else {
                            returnArr.append(strItem)
                        }
                    } else {
                        returnArr.append(item)
                    }
                }
                return returnArr
            }
        }
        
        return false
    }
}