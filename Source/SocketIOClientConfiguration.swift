//
//  SocketIOClientConfiguration.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 8/13/16.
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

public struct SocketIOClientConfiguration : ArrayLiteralConvertible, CollectionType, MutableCollectionType {
    public typealias Element = SocketIOClientOption
    public typealias Index = Array<SocketIOClientOption>.Index
    public typealias Generator = Array<SocketIOClientOption>.Generator
    public typealias SubSequence =  Array<SocketIOClientOption>.SubSequence
    
    private var backingArray = [SocketIOClientOption]()
    
    public var startIndex: Index {
        return backingArray.startIndex
    }
    
    public var endIndex: Index {
        return backingArray.endIndex
    }
    
    public var isEmpty: Bool {
        return backingArray.isEmpty
    }

    public var count: Index.Distance {
        return backingArray.count
    }
    
    public var first: Generator.Element? {
        return backingArray.first
    }
    
    public subscript(position: Index) -> Generator.Element {
        get {
            return backingArray[position]
        }
        
        set {
            backingArray[position] = newValue
        }
    }

    public subscript(bounds: Range<Index>) -> SubSequence {
        get {
            return backingArray[bounds]
        }
        
        set {
            backingArray[bounds] = newValue
        }
    }
    
    public init(arrayLiteral elements: Element...) {
        backingArray = elements
    }
    
    public func generate() -> Generator {
        return backingArray.generate()
    }
    
    public mutating func insert(element: Element, replacing replace: Bool = true) {
        for i in 0..<backingArray.count where backingArray[i] == element {
            guard replace else { return }
            
            backingArray[i] = element
            
            return
        }
        
        backingArray.append(element)
    }
    
    @warn_unused_result
    public func prefixUpTo(end: Index) -> SubSequence {
        return backingArray.prefixUpTo(end)
    }
    
    @warn_unused_result
    public func prefixThrough(position: Index) -> SubSequence {
        return backingArray.prefixThrough(position)
    }

    @warn_unused_result
    public func suffixFrom(start: Index) -> SubSequence {
        return backingArray.suffixFrom(start)
    }
}
