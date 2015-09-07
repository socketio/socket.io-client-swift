//
//  GenericSocketParser.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 07.09.15.
//
//

import Foundation

struct GenericParser {
    let message: String
    var currentIndex:Int
    var messageCharacters: Array<Character> {
        get {
            return Array(message.characters)
        }
    }
    var currentCharacter: String? {
        get{
            if currentIndex >= messageCharacters.count {
                return nil
            }
            return String(messageCharacters[currentIndex])
        }
    }
    
    mutating func read(characterLength:Int) -> String? {
        let startIndex = message.startIndex.advancedBy(currentIndex)
        let range = Range<String.Index>(start: startIndex, end: startIndex.advancedBy(characterLength))
        currentIndex = currentIndex + characterLength
        
        return message.substringWithRange(range)
    }
    
    mutating func readUntilStringOccurence(string:String) -> String? {
        let startIndex = message.startIndex.advancedBy(currentIndex)
        let range = Range<String.Index>(start: startIndex, end: message.endIndex)
        let subString = message.substringWithRange(range) as NSString
        let foundRange = subString.rangeOfString(string)
        if foundRange.location == Int.max {
            return nil
        }
        currentIndex = currentIndex + foundRange.location
        
        return subString.substringToIndex(foundRange.location)
    }
}