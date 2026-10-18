import Combine
import Foundation
import Mockable
import PbUtilities
import SwiftEnvironment

// MARK: - MonitorVisibility

/// Whether anyone can see the Monitor right now, so polling loops can stop driving
/// `polybridge-ctl` while nothing is displayed. Read side: consumers poll the getters, subscribe
/// to the deduped publishers, or park in `waitForMainWindowVisible()` while hidden. Write side:
/// the app shell feeds it through the setters — the main window's occlusion state from
/// `AppDelegate` (same closure-seam shape as `notifyBackendsAppActive`), and the menu-bar
/// popover's open state from the popover view's own appear/disappear lifecycle, which is the one
/// reliable signal a `MenuBarExtra` window offers.
///
/// "Visible" means a main window whose `occlusionState` contains `.visible` and that is not
/// miniaturized — a visible-but-unfocused Monitor beside a terminal keeps full polling cadence.
@Mockable
public protocol MonitorVisibility: Sendable {

    /// Whether a main window is currently visible (not occluded, not miniaturized).
    var mainWindowVisible: Bool { get }

    /// Whether the menu-bar popover content is currently shown.
    var menuBarPopoverOpen: Bool { get }

    /// Deduped `mainWindowVisible` — emits on change only.
    func mainWindowVisiblePublisher() -> AnyPublisher<Bool, Never>

    /// Deduped `menuBarPopoverOpen` — emits on change only.
    func menuBarPopoverOpenPublisher() -> AnyPublisher<Bool, Never>

    /// Returns once the main window is (again) visible — already-complete when it is visible now.
    /// A paused loop parks here, and the showing window wakes it for an immediate refresh.
    func waitForMainWindowVisible() async

    /// Fed by the app shell: the main window's visibility changed.
    func setMainWindowVisible(_ visible: Bool)

    /// Fed by the menu-bar popover's appear/disappear lifecycle.
    func setMenuBarPopoverOpen(_ open: Bool)
}

// MARK: - NullMonitorVisibility

/// A `@GlobalEntry` default that is always "visible": safe to resolve before `Module` registers
/// the real value, keeps any pre-registration consumer at full cadence instead of silently
/// pausing it, and never itself calls a `@MainActor` initialiser. Setters are no-ops — before the
/// module is initialized nobody is feeding real window state anyway.
public struct NullMonitorVisibility: MonitorVisibility {
    public init() {}
    public var mainWindowVisible: Bool { true }
    public var menuBarPopoverOpen: Bool { false }
    public func mainWindowVisiblePublisher() -> AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    public func menuBarPopoverOpenPublisher() -> AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    public func waitForMainWindowVisible() async {}
    public func setMainWindowVisible(_: Bool) {}
    public func setMenuBarPopoverOpen(_: Bool) {}
}

// MARK: - SystemMonitorVisibility

/// Production visibility state: deduped `@Subjected` values fed through the setters, and a
/// hidden-window `waitForMainWindowVisible()` that parks on the publisher until the next `true`.
public final class SystemMonitorVisibility: MonitorVisibility, @unchecked Sendable {

    @Subjected private var mainWindowVisibleValue: Bool
    @Subjected private var menuBarPopoverOpenValue = false

    /// The main window is on screen at launch, so visibility starts `true` until the app shell's
    /// first real observation says otherwise.
    public init(mainWindowVisible: Bool = true) {
        self.mainWindowVisibleValue = mainWindowVisible
    }

    public var mainWindowVisible: Bool { mainWindowVisibleValue }
    public var menuBarPopoverOpen: Bool { menuBarPopoverOpenValue }

    public func mainWindowVisiblePublisher() -> AnyPublisher<Bool, Never> {
        $mainWindowVisibleValue.removeDuplicates().eraseToAnyPublisher()
    }

    public func menuBarPopoverOpenPublisher() -> AnyPublisher<Bool, Never> {
        $menuBarPopoverOpenValue.removeDuplicates().eraseToAnyPublisher()
    }

    public func waitForMainWindowVisible() async {
        if mainWindowVisible { return }
        // A deduped CurrentValue-backed publisher re-emits the current `false` first; park until
        // the first `true`. Task cancellation ends the `for await` on its own.
        for await visible in mainWindowVisiblePublisher().values where visible { return }
    }

    public func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisibleValue = visible
    }

    public func setMenuBarPopoverOpen(_ open: Bool) {
        menuBarPopoverOpenValue = open
    }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global monitor visibility seam.
    @GlobalEntry var monitorVisibility: any MonitorVisibility = NullMonitorVisibility()
}
