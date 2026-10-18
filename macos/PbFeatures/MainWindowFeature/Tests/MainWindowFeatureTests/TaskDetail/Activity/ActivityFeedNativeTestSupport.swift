import AppKit
@testable import MainWindowFeature

/// A native cell is evidence only while realized in its correct semantic slot with hosted content.
@MainActor extension ActivityFeedNativeCell {
    var isCoherentNativePresentation: Bool {
        guard let table = enclosingScrollView?.documentView as? ActivityFeedNativeTableView,
              let owner = table.owner, let entryID, let host,
              window != nil, !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0,
              host.window === window, host.bounds.width > 0, host.bounds.height > 0 else { return false }
        let row = table.row(for: self)
        guard owner.entries.indices.contains(row), owner.entries[row].id == entryID, host.rootView.entry == owner.entries[row] else { return false }
        let slot = table.rect(ofRow: row)
        let frame = convert(bounds, to: table)
        let naturalHeight = host.fittingSize.height
        guard naturalHeight > owner.entries[row].topSpacing + 1,
              abs(naturalHeight - slot.height) < 3,
              let offeredWidth = host.rootView.availableWidth,
              let columnWidth = table.tableColumns.first?.width,
              abs(offeredWidth - columnWidth) < 1,
              abs(bounds.width - columnWidth) < 1 else { return false }
        return frame.minY >= slot.minY - 1 && frame.maxY <= slot.maxY + 1
            && frame.minX >= slot.minX - 1 && frame.maxX <= slot.maxX + 1
    }

    var isCoherentNativeMeasurement: Bool {
        guard isCoherentNativePresentation, let table = enclosingScrollView?.documentView as? ActivityFeedNativeTableView,
              let entryID else { return false }
        return table.owner?.entries.first { $0.id == entryID }?.anchorID != nil
    }

    var stableID: String? { isCoherentNativeMeasurement ? entryID : nil }

    /// Timeline-row commit evidence; independently changing tail revisions are excluded.
    var nativeSnapshotRevision: Int {
        guard let owner = (enclosingScrollView?.documentView as? ActivityFeedNativeTableView)?.owner else { return -1 }
        let rows = owner.boxes.filter { box in
            if case .row = box.entry { return true }
            return false
        }
        return rows.count + rows.reduce(0) { $0 + $1.revision }
    }
}

/// Walks modern accessibility objects and AppKit's legacy table proxies through public APIs.
@MainActor func activityNativeAccessibilityTree(_ root: NSObject) -> [NSObject] {
    var result: [NSObject] = []
    var visited = Set<ObjectIdentifier>()
    func visit(_ object: NSObject) {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return }
        result.append(object)
        let children: [Any] = if let modern = object as? any NSAccessibilityProtocol {
            modern.accessibilityChildren() ?? []
        } else {
            object.accessibilityAttributeValue(.children) as? [Any] ?? []
        }
        for child in children { if let child = child as? NSObject { visit(child) } }
        if let view = object as? NSView { view.subviews.forEach(visit) }
    }
    visit(root)
    return result
}

@MainActor func activityNativeAccessibilityStrings(_ root: NSObject) -> Set<String> {
    var strings = Set<String>()
    for object in activityNativeAccessibilityTree(root) {
        if let modern = object as? any NSAccessibilityProtocol {
            for text in [modern.accessibilityValue() as? String, modern.accessibilityTitle(), modern.accessibilityLabel()] {
                if let text { strings.insert(text) }
            }
        } else {
            for attribute: NSAccessibility.Attribute in [.value, .title, .description] {
                if let text = object.accessibilityAttributeValue(attribute) as? String { strings.insert(text) }
            }
        }
    }
    return strings
}

/// Deliberately reveal the latest content only after the paused-reading assertions completed.
@MainActor func activityNativeRevealBottom(_ scroll: NSScrollView) {
    (scroll as? ActivityFeedNativeScrollView)?.owner?.noteUserScrollEvent()
    let y = max(0, (scroll.documentView?.bounds.maxY ?? 0) - scroll.documentVisibleRect.height)
    scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
}

/// Native committed data evidence. This is deliberately not an accessibility getter.
@MainActor func activityNativeCommittedTailStrings(_ root: NSView) -> Set<String> {
    var strings = Set<String>()
    for table in activityNativeDescendants(root).compactMap({ $0 as? ActivityFeedNativeTableView }) {
        for entry in table.owner?.entries ?? [] {
            guard case .tail(let presentation, _) = entry else { continue }
            switch presentation {
            case .absent: break
            case .plainText(let text): strings.insert(text)
            case .standard(let standard):
                if let line = standard.liveStep { strings.insert(line.text) }
                standard.pendingMessages.forEach { strings.insert($0.text) }
                standard.subTaskStrip?.children.forEach { strings.insert($0.title) }
            }
        }
    }
    return strings
}

@MainActor func activityNativeVisibleTail(_ root: NSView) -> ActivityFeedNativeCell? {
    activityNativeDescendants(root).compactMap { $0 as? ActivityFeedNativeCell }.first { cell in
        guard cell.isCoherentNativePresentation, cell.entryID == "activity-feed-tail",
              let scroll = cell.enclosingScrollView, let table = scroll.documentView else { return false }
        return cell.convert(cell.bounds, to: table).intersection(scroll.documentVisibleRect).height > 0
    }
}

/// Realized natural geometry plus nonblank raster evidence; actual AX is verified in the app.
@MainActor func activityNativeVisibleTailHasRenderedContent(_ root: NSView) -> Bool {
    guard let cell = activityNativeVisibleTail(root), let host = cell.host,
          let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    var first: NSColor?
    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            if let first, color != first { return true }
            if first == nil { first = color }
        }
    }
    return false
}

@MainActor func activityNativeTailPrerequisite(_ root: NSView) -> Bool {
    let tables = activityNativeDescendants(root).compactMap { $0 as? ActivityFeedNativeTableView }
    guard let owner = tables.first?.owner, owner.positioned else { return false }
    // Offscreen tail updates are committed data; initial/following tails require actual visible rendering.
    return owner.state?.followLive.isFollowing != true || activityNativeVisibleTailHasRenderedContent(root)
}

@MainActor func activityNativeDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(activityNativeDescendants)
}
