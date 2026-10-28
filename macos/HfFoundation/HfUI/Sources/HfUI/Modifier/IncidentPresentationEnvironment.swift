import SwiftUI

// MARK: - Incident presentation environment

public extension EnvironmentValues {
    /// The existing window presentation owner's retained failures; nil outside its subtree.
    /// Reading this value never creates another presentation context or incident store.
    @Entry var incidentPresentation: IncidentPresentation?
}
