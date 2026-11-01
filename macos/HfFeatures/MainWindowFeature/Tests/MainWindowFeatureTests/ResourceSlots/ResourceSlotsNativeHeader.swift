import AppKit
@testable import MainWindowFeature
import ObjectiveC
import Testing

@MainActor
func resourceSlotsNativeHeaders(_ fixture: RedesignHost, groupID: String) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    return fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
        seen.insert(ObjectIdentifier($0)).inserted
            && fixture.string($0, "accessibilityIdentifier") == "resource-slots-group-" + groupID
    }
}

struct ResourceSlotsNativeHeaderState: Equatable {
    let attribute: String
    let kind: String
    let expanded: Bool
}

@MainActor
func resourceSlotsNativeHeaderState(_ control: NSObject) -> ResourceSlotsNativeHeaderState? {
    let value = resourceSlotsNativeValue(control)
    if let text = value as? String, ["Expanded", "Collapsed"].contains(text) {
        return .init(attribute: "accessibilityValue", kind: "string", expanded: text == "Expanded")
    }
    if let number = value as? NSNumber, number == 0 || number == 1 {
        return .init(attribute: "accessibilityValue", kind: "number", expanded: number.boolValue)
    }
    if let expanded = resourceSlotsNativeExpanded(control) {
        return .init(attribute: "isAccessibilityExpanded", kind: "boolean", expanded: expanded)
    }
    return nil
}

@MainActor
func resourceSlotsRequireNativeHeader(_ control: NSObject, fixture: RedesignHost, expanded: Bool) throws {
    let role = fixture.string(control, "accessibilityRole") ?? "nil"
    try #require(["AXButton", "AXDisclosureTriangle"].contains(role), Comment(rawValue: "Unsupported native header role: " + role))
    let state = try #require(resourceSlotsNativeHeaderState(control), "Native header must expose an explicit readable expansion state")
    #expect(state.expanded == expanded, Comment(rawValue: "Native " + state.attribute + " must match the actual expansion state"))
}

@MainActor
func resourceSlotsNativeValue(_ control: NSObject) -> Any? {
    guard control.responds(to: NSSelectorFromString("accessibilityValue")) else { return nil }
    if let accessible = control as? any NSAccessibilityProtocol { return accessible.accessibilityValue() }
    return control.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
}

@MainActor
func resourceSlotsNativeFocused(_ control: NSObject) -> Bool? {
    guard control.responds(to: NSSelectorFromString("isAccessibilityFocused")) else { return nil }
    if let accessible = control as? any NSAccessibilityProtocol { return accessible.isAccessibilityFocused() }
    return resourceSlotsNativeBoolean(control, name: "isAccessibilityFocused")
}

@MainActor
func resourceSlotsNativeExpanded(_ control: NSObject) -> Bool? {
    guard control.responds(to: NSSelectorFromString("isAccessibilityExpanded")) else { return nil }
    if let accessible = control as? any NSAccessibilityProtocol { return accessible.isAccessibilityExpanded() }
    return resourceSlotsNativeBoolean(control, name: "isAccessibilityExpanded")
}

/// Only the two public no-argument NSAccessibility BOOL getters may use this runtime path.
@MainActor
private func resourceSlotsNativeBoolean(_ control: NSObject, name: String) -> Bool? {
    guard ["isAccessibilityFocused", "isAccessibilityExpanded"].contains(name) else { return nil }
    let selector = NSSelectorFromString(name)
    guard control.responds(to: selector), let objectClass = object_getClass(control),
          let method = class_getInstanceMethod(objectClass, selector), method_getNumberOfArguments(method) == 2 else { return nil }
    var receiver = [CChar](repeating: 0, count: 8)
    var command = [CChar](repeating: 0, count: 8)
    method_getArgumentType(method, 0, &receiver, receiver.count)
    method_getArgumentType(method, 1, &command, command.count)
    guard resourceSlotsLegacyTypeString(receiver) == "@", resourceSlotsLegacyTypeString(command) == ":" else { return nil }
    var encoding = [CChar](repeating: 0, count: 8)
    method_getReturnType(method, &encoding, encoding.count)
    let implementation = method_getImplementation(method)
    switch resourceSlotsLegacyTypeString(encoding) {
    case "B":
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(control, selector)
    case "c":
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int8
        return unsafeBitCast(implementation, to: Getter.self)(control, selector) != 0
    default: return nil
    }
}

@MainActor
func resourceSlotsModernFocusedObject(_ object: NSObject) -> NSObject? {
    let selector = NSSelectorFromString("accessibilityFocusedUIElement")
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? NSObject
}

/// Requests keyboard focus only through the modern typed setter, and only behind a
/// `responds(to:)` guard: the legacy `accessibilitySetValue(_:forAttribute:)` on a SwiftUI
/// accessibility node raises an unrecognized-selector ObjC exception inside the host, and
/// the crash-on-exception host must terminate on a real defect rather than swallow it.
@MainActor
func resourceSlotsRequestNativeFocus(_ control: NSObject) {
    let selector = NSSelectorFromString("setAccessibilityFocused:")
    guard control.responds(to: selector), let accessible = control as? any NSAccessibilityProtocol else { return }
    accessible.setAccessibilityFocused(true)
}

/// Every legacy NSAccessibility getter on a hosted node is guarded the same way: a SwiftUI
/// node may not respond to the informal-protocol selector at all. The calls go through the
/// runtime (`perform` / method introspection) because the declared informal-protocol methods
/// are deprecated; the crash-on-exception host must never see an unguarded call.
@MainActor
func resourceSlotsLegacyAttributeValue(_ object: NSObject, _ attribute: NSAccessibility.Attribute) -> Any? {
    let selector = NSSelectorFromString("accessibilityAttributeValue:")
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector, with: attribute.rawValue)?.takeUnretainedValue()
}

@MainActor
func resourceSlotsLegacyAttributeNames(_ object: NSObject) -> [Any]? {
    let selector = NSSelectorFromString("accessibilityAttributeNames")
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? [Any]
}

@MainActor
func resourceSlotsLegacyActionNames(_ object: NSObject) -> [Any]? {
    let selector = NSSelectorFromString("accessibilityActionNames")
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue() as? [Any]
}

@MainActor
func resourceSlotsLegacyIsAttributeSettable(_ object: NSObject, _ attribute: NSAccessibility.Attribute) -> Bool? {
    let selector = NSSelectorFromString("accessibilityIsAttributeSettable:")
    guard object.responds(to: selector), let objectClass = object_getClass(object),
          let method = class_getInstanceMethod(objectClass, selector), method_getNumberOfArguments(method) == 3 else { return nil }
    var receiver = [CChar](repeating: 0, count: 16)
    var command = [CChar](repeating: 0, count: 16)
    var argument = [CChar](repeating: 0, count: 16)
    method_getArgumentType(method, 0, &receiver, receiver.count)
    method_getArgumentType(method, 1, &command, command.count)
    method_getArgumentType(method, 2, &argument, argument.count)
    guard resourceSlotsLegacyTypeString(receiver) == "@", resourceSlotsLegacyTypeString(command) == ":",
          resourceSlotsLegacyTypeString(argument) == "@" else { return nil }
    var encoding = [CChar](repeating: 0, count: 16)
    method_getReturnType(method, &encoding, encoding.count)
    let implementation = method_getImplementation(method)
    switch resourceSlotsLegacyTypeString(encoding) {
    case "B":
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(implementation, to: Setter.self)(object, selector, attribute.rawValue as NSString)
    case "c":
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Int8
        return unsafeBitCast(implementation, to: Setter.self)(object, selector, attribute.rawValue as NSString) != 0
    default: return nil
    }
}

/// Runtime type strings arrive null-padded; decode without the deprecated `String(cString:)`.
private func resourceSlotsLegacyTypeString(_ buffer: [CChar]) -> String {
    String(bytes: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
}

@MainActor
func resourceSlotsNativeFocusedElement(_ fixture: RedesignHost) -> NSObject? {
    if let focused = resourceSlotsModernFocusedObject(fixture.window) ?? resourceSlotsModernFocusedObject(NSApp) { return focused }
    var seen = Set<ObjectIdentifier>()
    let focused = fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
        seen.insert(ObjectIdentifier($0)).inserted && resourceSlotsNativeFocused($0) == true
    }
    return focused.count == 1 ? focused.first : nil
}

@MainActor
func resourceSlotsNativeReaderSurvey(_ control: NSObject, fixture: RedesignHost) -> [String: String] {
    let modernValue = resourceSlotsNativeValue(control)
    return [
        "modernRole": fixture.string(control, "accessibilityRole") ?? "unreadable",
        "modernValue": String(describing: modernValue), "modernValueType": modernValue.map { String(describing: type(of: $0)) } ?? "nil",
        "modernFocused": String(describing: resourceSlotsNativeFocused(control)),
        "modernExpanded": String(describing: resourceSlotsNativeExpanded(control)),
        "modernWindowFocused": String(describing: resourceSlotsModernFocusedObject(fixture.window)),
        "modernAppFocused": String(describing: resourceSlotsModernFocusedObject(NSApp)),
        "legacyValue": String(describing: resourceSlotsLegacyAttributeValue(control, .value)),
        "legacyFocused": String(describing: resourceSlotsLegacyAttributeValue(control, .focused)),
        "legacyExpanded": String(describing: resourceSlotsLegacyAttributeValue(control, NSAccessibility.Attribute(rawValue: "AXExpanded"))),
        "legacyWindowFocused": String(describing: resourceSlotsLegacyAttributeValue(fixture.window, .focusedUIElement)),
        "legacyAppFocused": String(describing: resourceSlotsLegacyAttributeValue(NSApp, .focusedUIElement)),
        "responder": fixture.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    ]
}
