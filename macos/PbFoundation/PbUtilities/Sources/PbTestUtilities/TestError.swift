//
//  TestError.swift
//  PbTestUtilities
//

import Foundation

/// Common test errors for success and failure-path assertions.
public enum TestError: Error, Equatable {
    /// A predictable expected error.
    case expectedError
    /// A predictable unexpected error.
    case unexpectedError
    /// A custom test error message.
    case customError(String)
}
