import AppKit

/// The part of a native host that the Tab, trace and focus helpers need. `RedesignHost` conforms
/// without any change in behaviour; the shipping-shell fixture conforms too, so the same helpers
/// drive both hosts.
@MainActor
protocol ResourceSlotsNativeHosting: AnyObject {
    var window: NSWindow { get }
    /// The root view of the window's content (the hosting view that carries the screen under test).
    var contentRoot: NSView { get }
    var descendants: [NSView] { get }
    func elements(in object: NSObject) -> [NSObject]
    func element(_ label: String) -> NSObject?
    func string(_ object: NSObject, _ property: String) -> String?
    func frame(_ object: NSObject) -> CGRect?
}

extension RedesignHost: ResourceSlotsNativeHosting {
    var contentRoot: NSView { host }
}
