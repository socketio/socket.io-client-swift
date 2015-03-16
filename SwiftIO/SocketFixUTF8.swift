//
//  SocketFixUTF8.swift
//  Socket.IO-Swift
//
//  Created by Erik Little on 3/16/15.
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
// Adapted from: https://github.com/durbrow/fix-double-utf8.swift

import Foundation

var memoizer = [String: UnicodeScalar]()

func lookup(base:UnicodeScalar, combi:UnicodeScalar) -> UnicodeScalar {
    let combined = "\(base)\(combi)"
    
    if let y = memoizer[combined] {
        return y
    }
    
    for i in 0x80...0xFF {
        let ch = UnicodeScalar(i)
        
        if String(ch) == combined {
            memoizer[combined] = ch
            return ch
        }
    }
    let ch = UnicodeScalar(0xFFFD) // Unicode replacement character �
    
    memoizer[combined] = ch
    return ch
}

func fixDoubleUTF8(inout name:String) {
    var isASCII = true
    var y = [UInt8]()
    
    for ch in name.unicodeScalars {
        if ch.value < 0x80 {
            y.append(UInt8(ch))
            continue
        }
        isASCII = false
        
        if ch.value < 0x100 {
            y.append(UInt8(ch))
            continue
        }
        // might be a combining character that when combined with the
        // preceeding character maps to a codepoint in the UTF8 range
        if y.count == 0 {
            return
        }
        
        let last = y.removeLast()
        let repl = lookup(UnicodeScalar(last), ch)
        
        // the replacement needs to be in the UTF8 range
        if repl.value >= 0x100 {
            return
        }
        
        y.append(UInt8(repl))
    }
    
    if isASCII {
        return
    }
    
    y.append(0) // null terminator
    
    return y.withUnsafeBufferPointer {
        let cstr = UnsafePointer<CChar>($0.baseAddress) // typecase from uint8_t * to char *
        let rslt = String.fromCStringRepairingIllFormedUTF8(cstr) // -> (String, Bool)
        if let str = rslt.0 {
            if !rslt.hadError {
                name = str
            }
        }
        
        return
    }
}