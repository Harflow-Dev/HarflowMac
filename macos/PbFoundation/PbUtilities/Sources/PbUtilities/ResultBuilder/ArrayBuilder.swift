//
//  ArrayBuilder.swift
//  PbUtilities
//
//  Backs
//  `AlertContent`'s actions builder in PbCommon.
//

import Foundation

/// Result builder that collects optional expressions into an array.
@resultBuilder
public struct ArrayBuilder<Element> {
    
    // MARK: - ArrayBuilder.TypeAliases
    
    /// Optional expression accepted by this builder.
    public typealias Expression = Element?
    /// Intermediate builder component.
    public typealias Component = [Element]
    /// Final built result.
    public typealias Result = [Element]
    
    // MARK: - Public Methods
    
    /// Builds a component from an optional expression.
    ///
    /// - Parameter expression: Optional element expression.
    /// - Returns: A one-element array if value exists; otherwise empty.
    public static func buildExpression(_ expression: Element?) -> Component {
        guard let expression else { return [] }
        return [expression]
    }
    
    /// Builds a component from an array expression.
    ///
    /// - Parameter expression: Array of elements.
    /// - Returns: The array itself.
    public static func buildExpression(_ expression: [Element]) -> Component {
        expression
    }
    
    /// Builds a component from an optional component.
    @inlinable public static func buildOptional(_ component: Component?) -> Component {
        component ?? []
    }
    
    /// Selects the first branch component.
    @inlinable public static func buildEither(first component: Component) -> Component {
        component
    }
    
    /// Selects the second branch component.
    @inlinable public static func buildEither(second component: Component) -> Component {
        component
    }
    
    /// Flattens nested component arrays.
    @inlinable public static func buildArray(_ components: [Component]) -> Component {
        components.flatMap(\.self)
    }
    
    /// Builds a final component from variadic components.
    @inlinable public static func buildBlock(_ components: Component...) -> Component {
        buildArray(components)
    }
    
    /// Produces the final result.
    public static func buildFinalResult(_ component: Component) -> Result {
        component
    }
}
