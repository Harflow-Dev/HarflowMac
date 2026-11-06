import AppKit
import Foundation
import HfRepository

// MARK: - SidebarRailMenuTrackingProbe

/// Test-only probe that drives the hosted rail's native appearance menu from inside its own
/// tracking loop. The `NSMenu.didBeginTrackingNotification` observer and the bounded poll timer
/// are both armed BEFORE the public show-menu action fires, and the timer is registered in both
/// the `.default` and `.eventTracking` run-loop modes so its callbacks execute inside
/// `NSMenuTrackingSession`'s nested event loop, allowing this fixture to inspect and act while
/// native tracking owns the main loop.
/// Both callbacks deliver synchronously on the AppKit main thread (selector notification observer,
/// main run-loop timer), so main-actor isolation is assumed inside them — never hopped through
/// a `Task`, which would starve until tracking ends. No work leaves the main actor.
@MainActor
final class SidebarRailMenuTrackingProbe: NSObject {
    /// The first and only accepted tracking menu while armed; ambiguous extra menus fail.
    private(set) var acceptedTrackingCount = 0
    private(set) var sawAmbiguousTrackingMenu = false
    /// The exact first `NSMenu` the tracking notification delivered while armed.
    private(set) var ownedMenu: NSMenu?
    /// Every chosen visible, non-separator item belongs to `ownedMenu` (item.menu === menu).
    private(set) var ownedIdentityValid = false
    /// Exactly the three visible, non-separator choices System/Light/Dark.
    private(set) var choicesValid = false
    /// Exactly one item is natively `.on` — System — and Light/Dark are `.off`. The painted
    /// SwiftUI checkmark must surface as the native state; if it does not, the actual states are
    /// recorded and the assert fails — never faked or rebaselined.
    private(set) var initialStateValid = false
    /// Set before the one public press call, so a reentrant tick can never duplicate the attempt.
    private(set) var didAttemptLightPress = false
    private(set) var lightPressReturn: Bool?
    private(set) var vmAppearanceAfterPress: String?
    private(set) var vmChangeCountAfterPress: Int?
    private(set) var expired = false
    /// The first bounded failure reason, exactly as recorded.
    private(set) var failure: String?

    private var choices: [NSMenuItem] = []
    private var initialItemStates: [String: String] = [:]
    private var ignoredTrackingCount = 0
    private weak var viewModel: RailAppearanceCountingViewModel?
    private var observing = false
    private var timer: Timer?
    private var deadline: Date?
    private var armed = false
    private var evidenceWritten = false

    /// Settled once the single press attempt has returned, or a bounded failure was recorded.
    var settled: Bool { (didAttemptLightPress && lightPressReturn != nil) || failure != nil }

    init(viewModel: RailAppearanceCountingViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    // MARK: Arming — strictly before the public show-menu action

    func arm(deadline: TimeInterval) {
        guard !armed else { return }
        armed = true
        self.deadline = Date().addingTimeInterval(deadline)
        NotificationCenter.default.addObserver(
            self, selector: #selector(receiveTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil
        )
        observing = true
        let poll = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(poll, forMode: .default)
        RunLoop.main.add(poll, forMode: .eventTracking)
        timer = poll
    }

    // MARK: Tracking callbacks

    @objc private func receiveTracking(_ note: Notification) {
        precondition(Thread.isMainThread, "AppKit menu tracking must remain on the main thread")
        trackingDidBegin(note.object as? NSMenu)
    }

    private func trackingDidBegin(_ trackingMenu: NSMenu?) {
        guard armed else { return }
        guard let menu = trackingMenu else {
            recordFailure("trackingObjectNotNSMenu")
            return
        }
        let titles = visibleNonSeparatorItems(in: menu).map(\.title)
        guard titles.count == 3,
              ["System", "Light", "Dark"].allSatisfy({ title in titles.filter { $0 == title }.count == 1 }) else {
            ignoredTrackingCount += 1
            return
        }
        acceptedTrackingCount += 1
        if ownedMenu != nil {
            sawAmbiguousTrackingMenu = true
            recordFailure("ambiguousTrackingMenu")
            return
        }
        ownedMenu = menu
        reconcile(menu)
    }

    private func tick() {
        guard armed else { return }
        if let deadline, Date() >= deadline {
            expired = true
            recordFailure("deadlineExpired")
            // Evidence and disarm come first; late callbacks must be inert. Only the known
            // owned menu is ever cancelled — with no owned menu nothing is touched, unknown
            // menus are never globally cancelled, and the production runner's hard process
            // bound remains the honest last resort outside this probe.
            writeEvidence()
            disarm()
            ownedMenu?.cancelTracking()
            return
        }
        guard let menu = ownedMenu, !didAttemptLightPress else { return }
        guard let light = visibleNonSeparatorItems(in: menu).first(where: { $0.title == "Light" }),
              lightReady(light) else { return }
        selectLight(light, ownedMenu: menu)
    }

    // MARK: Owned-menu verification

    private func reconcile(_ menu: NSMenu) {
        choices = visibleNonSeparatorItems(in: menu)
        initialItemStates = Dictionary(uniqueKeysWithValues: choices.map { ($0.title, stateName($0.state)) })
        let titles = choices.map(\.title)
        choicesValid = titles.count == 3
            && ["System", "Light", "Dark"].allSatisfy { title in titles.filter { $0 == title }.count == 1 }
        ownedIdentityValid = choices.allSatisfy { $0.menu === menu }
        initialStateValid = nativeState(of: "System") == .on
            && nativeState(of: "Light") == .off
            && nativeState(of: "Dark") == .off
        if !choicesValid { recordFailure("choices") }
        if !ownedIdentityValid { recordFailure("ownedIdentity") }
        if !initialStateValid { recordFailure("initialSelectionState") }
    }

    private func visibleNonSeparatorItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
    }

    private func nativeState(of title: String) -> NSControl.StateValue? {
        choices.first { $0.title == title }?.state
    }

    /// Readiness is read from the Light item's own modern public accessibility surface — role,
    /// title, a nonempty AX frame and the allowed press selector — never a tested flag, a fixed
    /// sleep or `responds(to:)` alone.
    private func lightReady(_ item: NSMenuItem) -> Bool {
        item.accessibilityRole()?.rawValue == NSAccessibility.Role.menuItem.rawValue
            && item.accessibilityTitle() == "Light"
            && !item.accessibilityFrame().isEmpty
            && item.isEnabled && item.isAccessibilityEnabled()
            && item.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")) == true
    }

    // MARK: The one public selection

    private func selectLight(_ light: NSMenuItem, ownedMenu menu: NSMenu) {
        guard light.menu === menu else {
            recordFailure("lightOwnershipChanged")
            writeEvidence()
            disarm()
            menu.cancelTracking()
            return
        }
        // Reentrancy guard first: no tick can enter the press twice.
        didAttemptLightPress = true
        lightPressReturn = light.accessibilityPerformPress()
        vmAppearanceAfterPress = viewModel?.appAppearance.rawValue
        vmChangeCountAfterPress = viewModel?.appearanceChangeCount
        writeEvidence()
        disarm()
        // Exit the loop if the selection did not already close the menu — the owned menu only.
        menu.cancelTracking()
    }

    // MARK: Teardown

    /// Hosted-fixture teardown: disarm first, then cancel only the retained owned menu if the
    /// tracking loop somehow still runs. Idempotent; late callbacks are no-ops.
    func finish() {
        writeEvidence()
        disarm()
        ownedMenu?.cancelTracking()
    }

    /// Idempotent: invalidates the timer and removes the observer BEFORE any known-menu cancel.
    /// All captures are weak, so nothing retains the probe.
    private func disarm() {
        armed = false
        if observing {
            NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
            observing = false
        }
        timer?.invalidate()
        timer = nil
        deadline = nil
    }

    private func recordFailure(_ reason: String) {
        if failure == nil { failure = reason }
    }

    // MARK: Bounded tracking evidence

    /// One bounded JSON per probe run, written before any cancel into the primary's existing
    /// capture directory: the actual titles, roles, native states, AX frames and owned identity
    /// of the exact items, plus the recorded action result and VM effect — never faked values,
    /// never a substitute surface, no personal paths, no stdout.
    private func writeEvidence() {
        guard !evidenceWritten else { return }
        evidenceWritten = true
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        let menu = ownedMenu
        let items = choices.map { (item: NSMenuItem) -> [String: Any] in
            ["title": item.title,
             "role": (item.accessibilityRole()?.rawValue as Any?) ?? NSNull(),
             "state": stateName(item.state),
             "frame": NSStringFromRect(item.accessibilityFrame()),
             "owned": item.menu === menu] as [String: Any]
        }
        let payload: [String: Any] = [
            "acceptedTrackingCount": acceptedTrackingCount,
            "ignoredTrackingCount": ignoredTrackingCount,
            "initialItemStates": initialItemStates,
            "ambiguousTrackingMenu": sawAmbiguousTrackingMenu,
            "ownedMenuType": (menu.map { String(describing: type(of: $0)) } as Any?) ?? NSNull(),
            "choicesValid": choicesValid,
            "ownedIdentityValid": ownedIdentityValid,
            "initialStateValid": initialStateValid,
            "didAttemptLightPress": didAttemptLightPress,
            "lightPressReturn": (lightPressReturn as Any?) ?? NSNull(),
            "vmAppearanceAfterPress": (vmAppearanceAfterPress as Any?) ?? NSNull(),
            "vmChangeCountAfterPress": (vmChangeCountAfterPress as Any?) ?? NSNull(),
            "expired": expired,
            "failure": (failure as Any?) ?? NSNull(),
            "items": items
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("rail-menu-tracking.json"))
    }

    private func stateName(_ state: NSControl.StateValue) -> String {
        switch state {
        case .on: "on"
        case .off: "off"
        case .mixed: "mixed"
        default: "unknown(\(state.rawValue))"
        }
    }
}
