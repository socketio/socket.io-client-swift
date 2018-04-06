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

/// An array-like type that holds `SocketIOClientOption`s
public struct SocketIOClientConfiguration : ExpressibleByArrayLiteral, Collection, MutableCollection {
    // MARK: Typealiases

    /// Type of element stored.
    public typealias Element = SocketIOClientOption

    /// Index type.
    public typealias Index = Array<SocketIOClientOption>.Index

    /// Iterator type.
    public typealias Iterator = Array<SocketIOClientOption>.Iterator

    /// SubSequence type.
    public typealias SubSequence =  Array<SocketIOClientOption>.SubSequence

    // MARK: Properties

    private var backingArray = [SocketIOClientOption]()

    /// The start index of this collection.
    public var startIndex: Index {
        return backingArray.startIndex
    }

    /// The end index of this collection.
    public var endIndex: Index {
        return backingArray.endIndex
    }

    /// Whether this collection is empty.
    public var isEmpty: Bool {
        return backingArray.isEmpty
    }

    /// The number of elements stored in this collection.
    public var count: Index.Stride {
        return backingArray.count
    }

    /// The first element in this collection.
    public var first: Element? {
        return backingArray.first
    }

    public subscript(position: Index) -> Element {
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

    // MARK: Initializers

    /// Creates a new `SocketIOClientConfiguration` from an array literal.
    ///
    /// - parameter arrayLiteral: The elements.
    public init(arrayLiteral elements: Element...) {
        backingArray = elements
    }

    // MARK: Methods

    /// Creates an iterator for this collection.
    ///
    /// - returns: An iterator over this collection.
    public func makeIterator() -> Iterator {
        return backingArray.makeIterator()
    }

    /// - returns: The index after index.
    public func index(after i: Index) -> Index {
        return backingArray.index(after: i)
    }

    /// Special method that inserts `element` into the collection, replacing any other instances of `element`.
    ///
    /// - parameter element: The element to insert.
    /// - parameter replacing: Whether to replace any occurrences of element to the new item. Default is `true`.
    public mutating func insert(_ element: Element, replacing replace: Bool = true) {
        for i in 0..<backingArray.count where backingArray[i] == element {
            guard replace else { return }

            backingArray[i] = element

            return
        }

        backingArray.append(element)
    }
}

/// Declares that a type can set configs from a `SocketIOClientConfiguration`.
public protocol ConfigSettable {
    // MARK: Methods

    /// Called when an `ConfigSettable` should set/update its configs from a given configuration.
    ///
    /// - parameter config: The `SocketIOClientConfiguration` that should be used to set/update configs.
    mutating func setConfigs(_ config: SocketIOClientConfiguration)
}
