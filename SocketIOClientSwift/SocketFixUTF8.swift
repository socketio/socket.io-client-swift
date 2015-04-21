//
//  SocketFixUTF8.swift
//  Socket.IO-Swift
//
//  Created by Erik Little on 3/16/15.
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

func fixDoubleUTF8(inout name:String) {
    let utf8 = name.dataUsingEncoding(NSISOLatin1StringEncoding)!
    let latin1 = NSString(data: utf8, encoding: NSUTF8StringEncoding)!
    name = latin1 as String
}

func doubleEncodeUTF8(inout str:String) {
    let latin1 = str.dataUsingEncoding(NSUTF8StringEncoding)!
    let utf8 = NSString(data: latin1, encoding: NSISOLatin1StringEncoding)!
    str = utf8 as String
}
