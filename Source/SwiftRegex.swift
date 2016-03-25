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

infix operator <~ { associativity none precedence 130 }

private let lock = dispatch_semaphore_create(1)
private var swiftRegexCache = [String: NSRegularExpression]()

internal final class SwiftRegex : NSObject, Boolean {
    var target: String
    var regex: NSRegularExpression
    
    init(target:String, pattern:String, options:NSRegularExpressionOptions?) {
        self.target = target
        
        if dispatch_semaphore_wait(lock, dispatch_time(DISPATCH_TIME_NOW, Int64(10 * NSEC_PER_MSEC))) != 0 {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options:
                    NSRegularExpressionOptions.dotMatchesLineSeparators)
                self.regex = regex
            } catch let error as NSError {
                SwiftRegex.failure("Error in pattern: \(pattern) - \(error)")
                self.regex = NSRegularExpression()
            }
            
            super.init()
            return
        }
        
        if let regex = swiftRegexCache[pattern] {
            self.regex = regex
        } else {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options:
                    NSRegularExpressionOptions.dotMatchesLineSeparators)
                swiftRegexCache[pattern] = regex
                self.regex = regex
            } catch let error as NSError {
                SwiftRegex.failure("Error in pattern: \(pattern) - \(error)")
                self.regex = NSRegularExpression()
            }
        }
        dispatch_semaphore_signal(lock)
        super.init()
    }

    private static func failure(message: String) {
        fatalError("SwiftRegex: \(message)")
    }

    private var targetRange: NSRange {
        return NSRange(location: 0,length: target.utf16.count)
    }
    
    private func substring(range: NSRange) -> String? {
        if range.location != NSNotFound {
            return (target as NSString).substring(with: range)
        } else {
            return nil
        }
    }
    
    func doesMatch(options: NSMatchingOptions!) -> Bool {
        return range(options).location != NSNotFound
    }
    
    func range(options: NSMatchingOptions) -> NSRange {
        return regex.rangeOfFirstMatch(in: target as String, options: [], range: targetRange)
    }
    
    func match(options: NSMatchingOptions) -> String? {
        return substring(range(options))
    }
    
    func groups() -> [String]? {
        return groupsForMatch(regex.firstMatch(in: target as String, options:
            NSMatchingOptions.withoutAnchoringBounds, range: targetRange))
    }
    
    private func groupsForMatch(match: NSTextCheckingResult?) -> [String]? {
        guard let match = match else {
            return nil
        }
        var groups = [String]()
        for groupno in 0...regex.numberOfCaptureGroups {
            if let group = substring(match.range(at: groupno)) {
                groups += [group]
            } else {
                groups += ["_"] // avoids bridging problems
            }
        }
        return groups
    }
    
    subscript(groupno: Int) -> String? {
        get {
            return groups()?[groupno]
        }
        
        set(newValue) {
            if newValue == nil {
                return
            }
            
            for match in Array(matchResults().reversed()) {
                let replacement = regex.replacementString(for: match,
                    in: target as String, offset: 0, template: newValue!)
                let mut = NSMutableString(string: target)
                mut.replaceCharacters(in: match.range(at: groupno), with: replacement)
                
                target = mut as String
            }
        }
    }
    
    func matchResults() -> [NSTextCheckingResult] {
        let matches = regex.matches(in: target as String, options:
            NSMatchingOptions.withoutAnchoringBounds, range: targetRange)
            as [NSTextCheckingResult]
        
        return matches
    }
    
    func ranges() -> [NSRange] {
        return matchResults().map { $0.range }
    }
    
    func matches() -> [String] {
        return matchResults().map( { self.substring($0.range)!})
    }
    
    func allGroups() -> [[String]?] {
        return matchResults().map { self.groupsForMatch($0) }
    }
    
    func dictionary(options: NSMatchingOptions!) -> Dictionary<String,String> {
        var out = Dictionary<String,String>()
        for match in matchResults() {
            out[substring(match.range(at: 1))!] = substring(match.range(at: 2))!
        }
        return out
    }
    
    func substituteMatches(substitution: ((NSTextCheckingResult, UnsafeMutablePointer<ObjCBool>) -> String),
        options:NSMatchingOptions) -> String {
            let out = NSMutableString()
            var pos = 0
            
        regex.enumerateMatches(in: target as String, options: options, range: targetRange ) {match, flags, stop in
                let matchRange = match!.range
                out.append( self.substring(NSRange(location:pos, length:matchRange.location-pos))!)
                out.append( substitution(match!, stop) )
                pos = matchRange.location + matchRange.length
            }
            
            out.append(substring(NSRange(location:pos, length:targetRange.length-pos))!)
            
            return out as String
    }
    
    var boolValue: Bool {
        return doesMatch(nil)
    }
}

extension String {
    subscript(pattern: String, options: NSRegularExpressionOptions) -> SwiftRegex {
        return SwiftRegex(target: self, pattern: pattern, options: options)
    }
}

extension String {
    subscript(pattern: String) -> SwiftRegex {
        return SwiftRegex(target: self, pattern: pattern, options: nil)
    }
}

func <~ (left: SwiftRegex, right: String) -> String {
    return left.substituteMatches({match, stop in
        return left.regex.replacementString(for: match, in: left.target as String, offset: 0, template: right )
        }, options: [])
}
