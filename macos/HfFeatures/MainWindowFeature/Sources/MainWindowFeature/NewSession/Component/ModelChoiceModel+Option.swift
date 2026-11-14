import HfRepository

// MARK: - ModelChoiceModel + ModelOption

extension ModelChoiceModel {

    /// A suggestion row for an engine-provided model, carrying its selectable effort levels.
    init(_ option: ModelOption) {
        self.init(id: option.value, title: option.label, effortLevels: option.effortLevels)
    }
}
