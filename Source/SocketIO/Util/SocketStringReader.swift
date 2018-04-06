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
    var currentIndex: String.UTF16View.Index
    var hasNext: Bool {
        return currentIndex != message.utf16.endIndex
    }

    var currentCharacter: String {
        return String(UnicodeScalar(message.utf16[currentIndex])!)
    }

    init(message: String) {
        self.message = message
        currentIndex = message.utf16.startIndex
    }

    @discardableResult
    mutating func advance(by: Int) -> String.UTF16View.Index {
        currentIndex = message.utf16.index(currentIndex, offsetBy: by)

        return currentIndex
    }

    mutating func read(count: Int) -> String {
        let readString = String(message.utf16[currentIndex..<message.utf16.index(currentIndex, offsetBy: count)])!

        advance(by: count)

        return readString
    }

    mutating func readUntilOccurence(of string: String) -> String {
        let substring = message.utf16[currentIndex...]

        guard let foundIndex = substring.index(of: string.utf16.first!) else {
            currentIndex = message.utf16.endIndex

            return String(substring)!
        }

        advance(by: substring.distance(from: substring.startIndex, to: foundIndex) + 1)

        return String(substring[substring.startIndex..<foundIndex])!
    }

    mutating func readUntilEnd() -> String {
        return read(count: message.utf16.distance(from: currentIndex, to: message.utf16.endIndex))
    }
}
