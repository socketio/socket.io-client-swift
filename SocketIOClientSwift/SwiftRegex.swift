//
//  SwiftRegex.swift
//  SwiftRegex
//
//  Created by John Holdsworth on 26/06/2014.
//  Copyright (c) 2014 John Holdsworth.
//
//  $Id: //depot/SwiftRegex/SwiftRegex.swift#37 $
//
//  This code is in the public domain from:
//  https://github.com/johnno1962/SwiftRegex
//

import Foundation

var swiftRegexCache = [String: NSRegularExpression]()

public class SwiftRegex: NSObject, BooleanType {
    var target:String
    var regex: NSRegularExpression

    init(target:String, pattern:String, options:NSRegularExpressionOptions = nil) {
        self.target = target
        if let regex = swiftRegexCache[pattern] {
            self.regex = regex
        } else {
            var error: NSError?
            if let regex = NSRegularExpression(pattern: pattern, options:options, error:&error) {
                swiftRegexCache[pattern] = regex
                self.regex = regex
            }
            else {
                SwiftRegex.failure("Error in pattern: \(pattern) - \(error)")
                self.regex = NSRegularExpression()
            }
        }
        super.init()
    }

    class func failure(message: String) {
        println("SwiftRegex: "+message)
        //assert(false,"SwiftRegex: failed")
    }

    final var targetRange: NSRange {
        return NSRange(location: 0,length: count(target.utf16))
    }

    final func substring(range: NSRange) -> String? {
        if ( range.location != NSNotFound ) {
            return (target as NSString).substringWithRange(range)
        } else {
            return nil
        }
    }

    public func doesMatch(options: NSMatchingOptions = nil) -> Bool {
        return range(options: options).location != NSNotFound
    }

    public func range(options: NSMatchingOptions = nil) -> NSRange {
        return regex.rangeOfFirstMatchInString(target as String, options: nil, range: targetRange)
    }

    public func match(options: NSMatchingOptions = nil) -> String? {
        return substring(range(options: options))
    }

    public func groups(options: NSMatchingOptions = nil) -> [String]? {
        return groupsForMatch(regex.firstMatchInString(target as String, options: options, range: targetRange))
    }

    func groupsForMatch(match: NSTextCheckingResult!) -> [String]? {
        if match != nil {
            var groups = [String]()
            for groupno in 0...regex.numberOfCaptureGroups {
                if let group = substring(match.rangeAtIndex(groupno)) {
                    groups += [group]
                } else {
                    groups += ["_"] // avoids bridging problems
                }
            }
            return groups
        } else {
            return nil
        }
    }

    public subscript(groupno: Int) -> String? {
        get {
            return groups()?[groupno]
        }

        set(newValue) {
            if newValue == nil {
                return
            }

            for match in matchResults()!.reverse() {
                let replacement = regex.replacementStringForResult(match,
                    inString: target as String, offset: 0, template: newValue!)
                let mut = NSMutableString(string: target)
                mut.replaceCharactersInRange(match.rangeAtIndex(groupno), withString: replacement)

                target = mut as String
            }
        }
    }

    func matchResults(options: NSMatchingOptions = nil) -> [NSTextCheckingResult]? {
        let matches = regex.matchesInString(target as String, options: options, range: targetRange)
            as? [NSTextCheckingResult]

        if matches != nil {
            return matches!
        } else {
            return nil
        }
    }

    public func ranges(options: NSMatchingOptions = nil) -> [NSRange] {
        return matchResults(options: options)!.map { $0.range }
    }

    public func matches(options: NSMatchingOptions = nil) -> [String] {
        return matchResults(options: options)!.map( { self.substring($0.range)!})
    }

    public func allGroups(options: NSMatchingOptions = nil) -> [[String]?] {
        return matchResults(options: options)!.map {self.groupsForMatch($0)}
    }

    public func dictionary(options: NSMatchingOptions = nil) -> Dictionary<String,String> {
        var out = Dictionary<String,String>()
        for match in matchResults(options: options)! {
            out[substring(match.rangeAtIndex(1))!] = substring(match.rangeAtIndex(2))!
        }
        return out
    }

    func substituteMatches(substitution: ((NSTextCheckingResult, UnsafeMutablePointer<ObjCBool>) -> String),
        options:NSMatchingOptions = nil) -> String {
            let out = NSMutableString()
            var pos = 0

            regex.enumerateMatchesInString(target as String, options: options, range: targetRange ) {
                (match: NSTextCheckingResult!, flags: NSMatchingFlags, stop: UnsafeMutablePointer<ObjCBool>) in

                let matchRange = match.range
                out.appendString( self.substring(NSRange(location:pos, length:matchRange.location-pos))!)
                out.appendString( substitution(match, stop) )
                pos = matchRange.location + matchRange.length
            }

            out.appendString(substring(NSRange(location:pos, length:targetRange.length-pos))!)

            return out as String
    }

    public var boolValue: Bool {
        return doesMatch()
    }
}

extension String {
    public subscript(pattern: String, options: NSRegularExpressionOptions) -> SwiftRegex {
        return SwiftRegex(target: self, pattern: pattern, options: options)
    }
}

extension String {
    public subscript(pattern: String) -> SwiftRegex {
        return SwiftRegex(target: self, pattern: pattern)
    }
}

public func ~= (left: SwiftRegex, right: String) -> String {
    return left.substituteMatches({match, stop in
        return left.regex.replacementStringForResult( match,
            inString: left.target as String, offset: 0, template: right )
        }, options: nil)
}

public func ~= (left: SwiftRegex, right: [String]) -> String {
    var matchNumber = 0
    return left.substituteMatches({match, stop -> String in

        if ++matchNumber == right.count {
            stop.memory = true
        }

        return left.regex.replacementStringForResult( match,
            inString: left.target as String, offset: 0, template: right[matchNumber-1] )
        }, options: nil)
}

public func ~= (left: SwiftRegex, right: (String) -> String) -> String {
    // return right(left.substring(match.range))
    return left.substituteMatches(
        {match, stop -> String in
            right(left.substring(match.range)!)
        }, options: nil)
}

public func ~= (left: SwiftRegex, right: ([String]?) -> String) -> String {
    return left.substituteMatches({match, stop -> String in
        return right(left.groupsForMatch(match))
        }, options: nil)
}
