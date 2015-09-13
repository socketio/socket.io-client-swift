//
//  SocketStringReader.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 07.09.15.
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

struct SocketStringReader {
    let message: String
    var currentIndex: String.Index
    var hasNext: Bool {
        return currentIndex != message.endIndex
    }
    
    var currentCharacter: String {
        return String(message[currentIndex])
    }
    
    init(message: String) {
        self.message = message
        currentIndex = message.startIndex
    }
    
    mutating func advanceIndexBy(n: Int) {
        currentIndex = currentIndex.advancedBy(n)
    }
    
    mutating func read(readLength: Int) -> String {
        let range = Range<String.Index>(start: currentIndex, end: currentIndex.advancedBy(readLength))
        advanceIndexBy(readLength)
        
        return message.substringWithRange(range)
    }
    
    mutating func readUntilStringOccurence(string: String) -> String {
        let range = Range<String.Index>(start: currentIndex, end: message.endIndex)
        let subString = message.substringWithRange(range)
        guard let foundRange = subString.rangeOfString(string) else {
            let restOfString = message[currentIndex...message.endIndex.predecessor()]
            currentIndex = message.endIndex
            
            return restOfString
        }
        
        advanceIndexBy(message.startIndex.distanceTo(foundRange.startIndex) + 1)
        
        return subString.substringToIndex(foundRange.startIndex)
    }
    
    mutating func readUntilEnd() -> String {
        return read(currentIndex.distanceTo(message.endIndex))
    }
}