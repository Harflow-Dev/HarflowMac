//
//  View+Extensions.swift
//  PbUtilities
//
//  Only `eraseToAnyView` is needed here.
//

import Foundation
import SwiftUI

/// Convenience type-erasure helper.
public extension View {
    
    // MARK: - Public Methods
    
    /// Type-erases the view to `AnyView`.
    ///
    /// - Returns: The type-erased view.
    @inlinable func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}
