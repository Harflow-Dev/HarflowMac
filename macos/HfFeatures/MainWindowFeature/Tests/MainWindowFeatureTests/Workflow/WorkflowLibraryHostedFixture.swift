import Foundation
@testable import MainWindowFeature
import MonitorCore

// MARK: - WorkflowLibraryHostedFixture

@MainActor enum WorkflowLibraryHostedFixture {
    static func make(long: Bool = false) -> LibraryTestHarness {
        let harness = LibraryTestHarness()
        if long {
            harness.useCase.response = ["workflows": .array((0 ..< 30).map { index in
                .object(["name": .string("workflow-\(index)-" + String(repeating: "long-name-", count: 12)),
                         "definition": .object(["description": .string(String(repeating: "A long saved workflow description. ", count: 12)),
                                                "nodes": .array([.object([:])])])])
            })]
        }
        return harness
    }
}
