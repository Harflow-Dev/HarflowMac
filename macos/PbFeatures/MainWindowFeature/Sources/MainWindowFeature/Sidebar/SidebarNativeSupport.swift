import AppKit
import PbCommon
import PbUI
import SwiftUI

// MARK: - Native identity and responder ownership

@MainActor final class SidebarNativeItemBox: NSObject {
    var entry: SidebarListEntry
    var height: CGFloat?
    var fittingHeight: CGFloat?
    weak var reportingCell: SidebarNativeCell?
    var reportGeneration = 0
    /// Most recent valid preference report, independent of deferred native-height commitment.
    var latestHostedReport: CGFloat?
    var pendingHostedHeight: CGFloat?
    var entryRevision = 0
    var naturalHeight: CGFloat?
    var measurementKey: SidebarNativeMeasurementKey?
    init(_ entry: SidebarListEntry) { self.entry = entry }
}

@MainActor final class SidebarOwnedOutlineView: NSOutlineView {
    var onMove: ((MoveCommandDirection) -> Void)?
    var onLayout: (() -> Void)?
    var onWillLayout: (() -> Void)?
    var onDidLayout: (() -> Void)?

    override func moveLeft(_ sender: Any?) { if let onMove { onMove(.left) } else { super.moveLeft(sender) } }
    override func moveRight(_ sender: Any?) { if let onMove { onMove(.right) } else { super.moveRight(sender) } }
    override func layout() {
        onWillLayout?()
        super.layout()
        onLayout?()
        onDidLayout?()
    }
}

@MainActor final class SidebarNativeCell: NSTableCellView {
    var host: NSHostingView<SidebarNativeRow>?
    var animate = false
    var onProminence: (() -> Void)?
    var headingLabel: String?
    weak var association: SidebarNativeItemBox?
    var hasLaidOut = false
    var onLaidOut: (() -> Void)?
    var onDetached: (() -> Void)?
    private var wasAttached = false

    override func isAccessibilityElement() -> Bool {
        headingLabel != nil || super.isAccessibilityElement()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        headingLabel != nil ? .headingRole : super.accessibilityRole()
    }

    override func accessibilityLabel() -> String? {
        headingLabel ?? super.accessibilityLabel()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { onProminence?() } }
    }

    func configure(entry: SidebarListEntry, actions: SidebarNativeActions, selected: Bool, animate: Bool = false,
                   environment: EnvironmentValues, onHeight: @escaping @MainActor @Sendable (CGFloat) -> Void) {
        if case .workflowsHeader(let expanded) = entry.content {
            headingLabel = expanded ? "Collapse workflows" : "Expand workflows"
        } else {
            headingLabel = nil
        }
        let root = SidebarNativeRow(entry: entry, actions: actions, selected: selected, animate: animate,
                                    environment: environment, increasedProminence: backgroundStyle == .emphasized,
                                    availableWidth: frame.width > 0 ? frame.width : nil,
                                    occupiedHeight: onHeight)
        if let host {
            host.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }

    func measure(width: CGFloat) -> CGFloat? {
        guard width > 0, let host else { return nil }
        if host.rootView.availableWidth != width { host.rootView.availableWidth = width }
        let size = host.fittingSize
        return size.height.isFinite && size.height >= 0 ? size.height : nil
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
        hasLaidOut = true
        onLaidOut?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { wasAttached = true } else if wasAttached {
            wasAttached = false
            onDetached?()
        }
    }
}

@MainActor final class SidebarNativeWeakCell {
    weak var value: SidebarNativeCell?
    init(_ value: SidebarNativeCell) { self.value = value }
}

@MainActor struct SidebarNativeCellRegistry {
    private var storage: [SidebarDisplayID: SidebarNativeWeakCell] = [:]
    subscript(id: SidebarDisplayID) -> SidebarNativeCell? {
        get { storage[id]?.value }
        set { storage[id] = newValue.map(SidebarNativeWeakCell.init) }
    }

    mutating func removeValue(forKey id: SidebarDisplayID) { storage.removeValue(forKey: id) }
    mutating func removeAll() { storage.removeAll() }
    var count: Int { storage.values.reduce(0) { $0 + ($1.value == nil ? 0 : 1) } }
}

struct SidebarNativeMeasurementKey: Equatable {
    let entryRevision: Int
    let width: CGFloat
    let environmentRevision: Int
    let selected: Bool
    let emphasized: Bool
}

@MainActor final class SidebarNativeTransitionRelay {
    weak var coordinator: SidebarNativeList.Coordinator?
    func publish(fading: Set<String>, restored: Set<String>, epoch: Int) {
        coordinator?.transition(ids: fading, restored: restored, epoch: epoch, ended: false)
    }

    func end(_ ids: Set<String>, epoch: Int) {
        coordinator?.transition(ids: ids, restored: [], epoch: epoch, ended: true)
    }
}

// MARK: - Explicit inherited presentation inputs

struct SidebarNativeEnvironmentFingerprint: Equatable {
    let font: Font?
    let minimumHeight: CGFloat
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    let legibility: LegibilityWeight?
    let dynamicType: DynamicTypeSize
    let locale: Locale
    let direction: LayoutDirection
    let displayScale: CGFloat
    let controlSize: ControlSize
    let enabled: Bool
    let reduceMotion: Bool
    let motionOverride: Bool?
    let shimmerOverride: Bool?

    init(_ environment: EnvironmentValues) {
        self.font = environment.font
        self.minimumHeight = environment.defaultMinListRowHeight
        self.colorScheme = environment.colorScheme
        self.contrast = environment.colorSchemeContrast
        self.legibility = environment.legibilityWeight
        self.dynamicType = environment.dynamicTypeSize
        self.locale = environment.locale
        self.direction = environment.layoutDirection
        self.displayScale = environment.displayScale
        self.controlSize = environment.controlSize
        self.enabled = environment.isEnabled
        self.reduceMotion = environment.accessibilityReduceMotion
        self.motionOverride = environment.pbReduceMotionOverride
        self.shimmerOverride = environment.shimmerReduceMotionOverride
    }
}

struct SidebarNativeHistoryPublication: Equatable {
    let visible: Bool
    let revision: Int
    let token: String
}
