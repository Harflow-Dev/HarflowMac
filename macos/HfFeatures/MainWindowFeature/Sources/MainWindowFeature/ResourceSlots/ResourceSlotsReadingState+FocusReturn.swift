import AppKit

// MARK: - ResourceSlotsReadingState focus return

extension ResourceSlotsReadingState {
    /// `responder` captures the keyboard responder at Back. By default the departing keyboard
    /// focus is resigned to the content's own hosting window (recorded while mounted and kept
    /// across the departure) and the window is authorized, so the focus held by a control that
    /// the Back transition removes (the toolbar Back item, or a control in the detail being
    /// left) is never mistaken for a user's choice when the focus system reassigns it. The
    /// resign runs only when a return will be attempted, no explicit responder was passed, a
    /// window is recorded and its responder is not already the window. When the responder
    /// refuses to resign, or an explicit responder is passed, that responder is captured as
    /// before and stays neutral during restoration.
    ///
    /// Resigning ends field-editor editing in the detail being left, which commits or drops
    /// marked (IME) text. That is accepted: the detail unmounts at Back anyway.
    func authorizeFocusReturn(responder: NSResponder? = nil) {
        focusReturnAuthorized = focusedRowID != nil
        let host = keyFocusHost
        var resign = ResourceSlotsDiagnosticRecord.FocusResign.notNeeded
        guard focusReturnAuthorized else {
            focusResponder = nil
            recordAuthorization(host: host, resign: resign)
            return
        }
        if let responder {
            focusResponder = responder
        } else if !host.hasWindow() {
            resign = .noWindow
            focusResponder = host.currentResponder()
        } else if host.currentResponder() === host.windowResponder() {
            focusResponder = host.currentResponder()
        } else if host.resign() {
            resign = .resigned
            focusResponder = host.windowResponder()
        } else {
            resign = .refused
            focusResponder = host.currentResponder()
        }
        recordAuthorization(host: host, resign: resign)
    }

    private func recordAuthorization(host: ResourceSlotsKeyFocusHost, resign: ResourceSlotsDiagnosticRecord.FocusResign) {
        let kind: ResourceSlotsDiagnosticRecord.FocusAuthorizedKind = switch focusResponder {
        case nil: .absent
        case let responder? where responder === host.windowResponder(): .window
        case is NSView: .view
        default: .other
        }
        recordDiagnostic(event: "focus-authorized", focusResign: resign, focusAuthorizedKind: kind)
    }
}
