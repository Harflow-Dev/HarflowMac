import MonitorCore

// MARK: - WorkflowContextDelivery

/// Observed prompt delivery sizes; these are not model token measurements.
struct WorkflowContextDelivery {
    let task: [String: JSONValue]

    var lines: [String] {
        guard let delivery = task["context_delivery"]?.objectValue else { return [] }
        var result = ["Context: " + (delivery["mode"]?.stringValue ?? "unknown")]
        if let bytes = delivery["total_bytes"]?.intValue,
           let characters = delivery["total_characters"]?.intValue {
            result.append("Delivered \(bytes) bytes · \(characters) characters")
        }
        if let revision = delivery["revision"]?.intValue {
            result.append("Revision: \(revision)")
        }
        if let base = delivery["base_revision"]?.intValue {
            result.append("Acknowledged base: \(base)")
        }
        if let overflow = delivery["budget_overflow_bytes"]?.intValue, overflow > 0 {
            result.append("Required context exceeds target by \(overflow) bytes")
        }
        if let reason = delivery["compatibility_reason"]?.stringValue, !reason.isEmpty {
            result.append(reason)
        }
        if let sections = delivery["sections"]?.objectValue {
            for name in sections.keys.sorted() {
                if let bytes = sections[name]?["bytes"]?.intValue {
                    result.append("\(name): \(bytes) bytes")
                }
            }
        }
        if let usage = task["prompt_usage"]?["usage"], usage != .null {
            result.append("Reported model usage: " + usage.rendered())
        }
        if let cost = task["prompt_usage"]?["cost_usd"]?.doubleValue {
            result.append("Reported cost: $\(cost)")
        }
        return result
    }
}
