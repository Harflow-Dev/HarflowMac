import HfRepository

extension MainWindowGate {
    /// Whether the gate replaces the sidebar body with the setup line. The store gate does not: the drawing keeps the
    /// populated sidebar and its store link.
    var givesSidebarToSetupLine: Bool {
        if case .storeUnusable = self { return false }
        return true
    }
}
