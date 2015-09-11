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
    
    init(target:String, pattern:String, options:NSRegularExpressionOptions?) {
        self.target = target
        if let regex = swiftRegexCache[pattern] {
            self.regex = regex
        } else {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options:
                    NSRegularExpressionOptions.DotMatchesLineSeparators)
                swiftRegexCache[pattern] = regex
                self.regex = regex
            } catch let error1 as NSError {
                SwiftRegex.failure("Error in pattern: \(pattern) - \(error1)")
                self.regex = NSRegularExpression()
            }
        }
        super.init()
    }
	
	private static func failure(message: String) {
		fatalError("SwiftRegex: \(message)")
	}

    final var targetRange: NSRange {
        return NSRange(location: 0,length: target.utf16.count)
    }
    
    final func substring(range: NSRange) -> String? {
        if ( range.location != NSNotFound ) {
            return (target as NSString).substringWithRange(range)
        } else {
            return nil
        }
    }
    
    public func doesMatch(options: NSMatchingOptions!) -> Bool {
        return range(options).location != NSNotFound
    }
    
    public func range(options: NSMatchingOptions) -> NSRange {
        return regex.rangeOfFirstMatchInString(target as String, options: [], range: targetRange)
    }
    
    public func match(options: NSMatchingOptions) -> String? {
        return substring(range(options))
    }
    
    public func groups() -> [String]? {
        return groupsForMatch(regex.firstMatchInString(target as String, options:
            NSMatchingOptions.WithoutAnchoringBounds, range: targetRange))
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
            
            for match in Array(matchResults().reverse()) {
                let replacement = regex.replacementStringForResult(match,
                    inString: target as String, offset: 0, template: newValue!)
                let mut = NSMutableString(string: target)
                mut.replaceCharactersInRange(match.rangeAtIndex(groupno), withString: replacement)
                
                target = mut as String
            }
        }
    }
    
    func matchResults() -> [NSTextCheckingResult] {
        let matches = regex.matchesInString(target as String, options:
            NSMatchingOptions.WithoutAnchoringBounds, range: targetRange)
            as [NSTextCheckingResult]
        
        return matches
    }
    
    public func ranges() -> [NSRange] {
        return matchResults().map { $0.range }
    }
    
    public func matches() -> [String] {
        return matchResults().map( { self.substring($0.range)!})
    }
    
    public func allGroups() -> [[String]?] {
        return matchResults().map {self.groupsForMatch($0)}
    }
    
    public func dictionary(options: NSMatchingOptions!) -> Dictionary<String,String> {
        var out = Dictionary<String,String>()
        for match in matchResults() {
            out[substring(match.rangeAtIndex(1))!] = substring(match.rangeAtIndex(2))!
        }
        return out
    }
    
    func substituteMatches(substitution: ((NSTextCheckingResult, UnsafeMutablePointer<ObjCBool>) -> String),
        options:NSMatchingOptions) -> String {
            let out = NSMutableString()
            var pos = 0
            
            regex.enumerateMatchesInString(target as String, options: options, range: targetRange ) {match, flags, stop in
                let matchRange = match!.range
                out.appendString( self.substring(NSRange(location:pos, length:matchRange.location-pos))!)
                out.appendString( substitution(match!, stop) )
                pos = matchRange.location + matchRange.length
            }
            
            out.appendString(substring(NSRange(location:pos, length:targetRange.length-pos))!)
            
            return out as String
    }
    
    public var boolValue: Bool {
        return doesMatch(nil)
    }
}

extension String {
    public subscript(pattern: String, options: NSRegularExpressionOptions) -> SwiftRegex {
        return SwiftRegex(target: self, pattern: pattern, options: options)
    }
}

extension String {
    public subscript(pattern: String) -> SwiftRegex {
        return SwiftRegex(target: self, pattern: pattern, options: nil)
    }
}

public func ~= (left: SwiftRegex, right: String) -> String {
    return left.substituteMatches({match, stop in
        return left.regex.replacementStringForResult( match,
            inString: left.target as String, offset: 0, template: right )
        }, options: [])
}

public func ~= (left: SwiftRegex, right: [String]) -> String {
    var matchNumber = 0
    return left.substituteMatches({match, stop -> String in
        
        if ++matchNumber == right.count {
            stop.memory = true
        }
        
        return left.regex.replacementStringForResult( match,
            inString: left.target as String, offset: 0, template: right[matchNumber-1] )
        }, options: [])
}

public func ~= (left: SwiftRegex, right: (String) -> String) -> String {
    // return right(left.substring(match.range))
    return left.substituteMatches(
        {match, stop -> String in
            right(left.substring(match.range)!)
        }, options: [])
}

public func ~= (left: SwiftRegex, right: ([String]?) -> String) -> String {
    return left.substituteMatches({match, stop -> String in
        return right(left.groupsForMatch(match))
        }, options: [])
}
