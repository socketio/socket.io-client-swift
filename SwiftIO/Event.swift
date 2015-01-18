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
    var currentPlace = 0
    var event:String!
    lazy var datas = [NSData]()
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
    
    func createMessage() -> String {
        var array = "42["
        array += "\"" + event + "\""
        
        if args? != nil {
            if args is NSDictionary {
                array += ","
                var jsonSendError:NSError?
                var jsonSend = NSJSONSerialization.dataWithJSONObject(args as NSDictionary,
                    options: NSJSONWritingOptions(0), error: &jsonSendError)
                var jsonString = NSString(data: jsonSend!, encoding: NSUTF8StringEncoding)
                return array + jsonString! + "]"
            } else {
                array += ",\"\(args!)\""
                return array + "]"
            }
        } else {
            return array + "]"
        }
    }
    
    func createBinaryMessage() -> String {
        var array = "45\(self.placeholders)-["
        array += "\"" + event + "\""
        if args? != nil {
            if args is NSDictionary {
                array += ","
                var jsonSendError:NSError?
                var jsonSend = NSJSONSerialization.dataWithJSONObject(args as NSDictionary,
                    options: NSJSONWritingOptions(0), error: &jsonSendError)
                var jsonString = NSString(data: jsonSend!, encoding: NSUTF8StringEncoding)
                return array + jsonString! + "]"
            } else {
                array += ",\"\(args!)\""
                return array + "]"
            }
        } else {
            return array + "]"
        }
    }
    
    func fillInPlaceholders(args:AnyObject) -> AnyObject {
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
        }
        
        return false
    }
}