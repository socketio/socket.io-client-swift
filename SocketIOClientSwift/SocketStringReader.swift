//
//  SocketStringReader.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 07.09.15.
//
//

import Foundation

struct SocketStringReader {
    let message: String
    var currentIndex: String.Index
    var hasNext: Bool {
        return currentIndex != message.endIndex
    }
    
    var currentCharacter: String {
        return String(message[currentIndex])
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
        let subString = message.substringWithRange(range) as NSString
        let foundRange = subString.rangeOfString(string)
        
        if foundRange.length == 0 {
            let restOfString = message[currentIndex...message.endIndex.predecessor()]
            currentIndex = message.endIndex
            
            return restOfString
        }
        
        advanceIndexBy(foundRange.location + 1)
        
        return subString.substringToIndex(foundRange.location)
    }
    
    mutating func readUntilEnd() -> String {
        return read(currentIndex.distanceTo(message.endIndex))
    }
}