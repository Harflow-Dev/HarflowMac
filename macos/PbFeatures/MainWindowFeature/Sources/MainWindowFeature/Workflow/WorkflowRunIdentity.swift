import Foundation

// MARK: - WorkflowRunIdentity

/// Matches Polybridge's run identifier contract before sending a run-scoped command.
enum WorkflowRunIdentity {
    static func isValid(_ id: String) -> Bool {
        let bytes = id.utf8
        guard (1 ... 100).contains(bytes.count), let first = bytes.first,
              (65 ... 90).contains(first) || (97 ... 122).contains(first) || (48 ... 57).contains(first) else { return false }
        return bytes.allSatisfy { byte in
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte)
                || byte == 46 || byte == 45 || byte == 95
        }
    }
}
