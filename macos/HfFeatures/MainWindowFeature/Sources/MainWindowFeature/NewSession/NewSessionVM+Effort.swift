import HfRepository

// MARK: - NewSessionVM + effort

extension NewSessionVM {

    /// The harness controls as narrowed by the model typed exactly as one of this harness's suggestions
    /// (surrounding whitespace ignored). Resolved from `modelOptions`, never from `modelChoices`, which holds
    /// the synthetic "Default" row. Only effort can differ from `controls`; the harness always has the last word.
    var effectiveControls: BackendControls {
        BackendControls.effectiveControls(harness: controls, modelEffortLevels: modelOptions.effortLevels(forModel: model))
    }
}
