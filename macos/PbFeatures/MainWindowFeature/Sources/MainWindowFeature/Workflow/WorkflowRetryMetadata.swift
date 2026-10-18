import MonitorCore

// MARK: - WorkflowRetryMetadata

enum WorkflowRetryMetadata {
    static func topology(_ definition: [String: JSONValue]) -> JSONValue {
        func records(_ key: String, fields: [String]) -> JSONValue {
            .array(WorkflowJSON.objects(definition[key]).sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") }.map { entry in
                .object(Dictionary(uniqueKeysWithValues: fields.map { ($0, entry[$0] ?? .null) }))
            })
        }
        return .object(["nodes": records("nodes", fields: ["id", "type"]),
                        "connections": records("connections", fields: ["id", "source", "target"])])
    }
}
