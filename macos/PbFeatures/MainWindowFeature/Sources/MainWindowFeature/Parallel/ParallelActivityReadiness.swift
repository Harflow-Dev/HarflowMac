//
//  ParallelActivityReadiness.swift
//  MainWindowFeature
//
//  Split out of ParallelVM.swift purely to keep that file under the swiftlint length budget —
//  same protocol, same behaviour. The optional capability `ParallelVM` casts its use case for so
//  activity waits for the repository's readiness signal instead of assuming it.
//

import Combine

// MARK: - ParallelActivityReadiness

@MainActor
protocol ParallelActivityReadiness {
    func activityReadyPublisher() -> AnyPublisher<Bool, Never>
}
