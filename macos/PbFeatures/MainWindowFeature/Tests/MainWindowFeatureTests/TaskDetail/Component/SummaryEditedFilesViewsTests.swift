import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - SummaryEditedFilesViewsTests

@MainActor @Suite(.serialized) struct SummaryEditedFilesViewsTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenTheFilesHeading_whenHostedWideAndNarrow_thenTheFullCaveatWrapsBesideTheCount(scheme: ColorScheme) async throws {
        // given
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let wideWidth = PbRadius.Metrics.taskColumnMaxWidth - 2 * PbRadius.Metrics.spacing24
        let host = NSHostingView(rootView: SummaryEditedFilesHeading(count: 3).preferredColorScheme(scheme))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: wideWidth, height: PbRadius.Metrics.sidebarCompactPreviewHeight),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            return element(SummaryEditedFilesHeading.caveat, in: host) != nil
        }
        let title = try #require(element("Files edited · 3", in: host))
        let caption = try #require(element(SummaryEditedFilesHeading.caveat, in: host))
        let titleFrame = try #require(frame(title))
        let wideCaption = try #require(frame(caption))
        // then — the caveat is beside the heading at the default reading measure.
        #expect(wideCaption.minX >= titleFrame.maxX)
        #expect(wideCaption.height > 0)
        // when — the same complete caption wraps in a narrow pane.
        window.setContentSize(CGSize(width: PbRadius.Metrics.activityPreviewWidth, height: PbRadius.Metrics.sidebarCompactPreviewHeight))
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return (element(SummaryEditedFilesHeading.caveat, in: host).flatMap(frame)?.height ?? 0) > wideCaption.height
        }
        let narrowCaption = try #require(element(SummaryEditedFilesHeading.caveat, in: host).flatMap(frame))
        let narrowTitle = try #require(element("Files edited · 3", in: host).flatMap(frame))
        // then — no caveat truncation; the count remains beside it or above the narrow stacked caption.
        #expect(narrowCaption.height > wideCaption.height)
        #expect(narrowCaption.minX >= narrowTitle.maxX || narrowCaption.maxY <= narrowTitle.minY)
        #expect(narrowCaption.maxX <= window.convertToScreen(window.contentLayoutRect).maxX + 1)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenGroupedEditedFailedAndUnconfirmedFiles_whenHostedNarrow_thenAllStatusLabelsRemainNonactionable(scheme: ColorScheme) async throws {
        // given
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let files = [EditedFileStatus.edited, .failed, .unconfirmed].enumerated().map { index, status in
            SummaryFileRow(EditedFile(path: "/repo/Sources/File\(index).swift", status: status))
        }
        let host = NSHostingView(rootView: SummaryEditedFilesCard(rows: files)
.preferredColorScheme(scheme)
.frame(width: PbRadius.Metrics.activityPreviewWidth))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: PbRadius.Metrics.activityPreviewWidth,
                                                 height: PbRadius.Metrics.sidebarCompactPreviewHeight),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            return files.allSatisfy { element($0.accessibilityLabel, in: host) != nil }
        }
        // then — adding a decorative file icon neither replaces status nor invents an open action.
        #expect(files.allSatisfy { element($0.accessibilityLabel, in: host) != nil })
        #expect(!tree(host).contains { string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue })
        #expect(host.fittingSize.width <= PbRadius.Metrics.activityPreviewWidth)
    }

    @Test(arguments: [ColorScheme.light, .dark], [PbRadius.Metrics.activityPreviewWidth, PbRadius.Metrics.taskColumnMaxWidth])
    func givenTheProductionFileCard_whenMeasuredAtNarrowAndWideWidths_thenRowsOwnExactSharedPaddingAndDividers(
        scheme: ColorScheme, width: CGFloat
    ) {
        // given
        _ = NSApplication.shared
        let files = [EditedFileStatus.edited, .failed, .unconfirmed].enumerated().map { index, status in
            SummaryFileRow(EditedFile(path: "/repo/Sources/File\(index).swift", status: status))
        }
        let contentWidth = width - 2 * PbRadius.Metrics.activityRowPaddingHorizontal
        // when — measure actual production row content and the same container used by SummaryPaneView.
        let rawHeight = files.map { measured(SummaryEditedFileRow(row: $0), width: contentWidth, scheme: scheme).height }.reduce(0, +)
        let card = measured(SummaryEditedFilesCard(rows: files), width: width, scheme: scheme)
        let expected = rawHeight + CGFloat(files.count) * 2 * PbRadius.Metrics.activityRowPaddingVertical
            + CGFloat(files.count - 1) * PbRadius.Metrics.hairlineStroke
        // then — no outer card padding or duplicate row padding; one full-width hairline per boundary.
        #expect(abs(card.height - expected) < 1)
        #expect(card.width <= width)
    }

    @Test func givenCollapsedAndAdditionalFiles_whenPressingProductionCardActions_thenShowLoadedAndLoadMoreStayDistinct() async throws {
        // given
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let row = SummaryFileRow(EditedFile(path: "/repo/A.swift", status: .edited))
        var reveals = 0
        var loads = 0
        let host = NSHostingView(rootView: SummaryEditedFilesCard(rows: [row], hiddenCount: 3, loadedCount: 4,
            additionalFileCount: 2, onShowLoaded: { reveals += 1 }, onLoadMore: { loads += 1 })
            .frame(width: PbRadius.Metrics.activityPreviewWidth))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: PbRadius.Metrics.activityPreviewWidth,
                                                 height: PbRadius.Metrics.sidebarCompactPreviewHeight),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            return element("Show loaded 4", in: host) != nil
        }
        let reveal = try #require(element("Show loaded 4", in: host))
        let load = try #require(element("Load more files (2 task file entries not shown)", in: host))
        // when
        #expect(press(reveal))
        // then
        #expect(reveals == 1)
        #expect(loads == 0)
        // when
        #expect(press(load))
        // then
        #expect(reveals == 1)
        #expect(loads == 1)
    }

    private func measured(_ view: some View, width: CGFloat, scheme: ColorScheme) -> CGSize {
        let host = NSHostingView(rootView: view.preferredColorScheme(scheme)
.frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func press(_ element: NSObject) -> Bool {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(element.method(for: selector), to: Press.self)
        return implementation(element, selector)
    }

    private func tree(_ element: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = element.responds(to: selector)
            ? element.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
        let subviews = (element as? NSView)?.subviews ?? []
        return [element] + children.flatMap(tree) + subviews.flatMap(tree)
    }

    private func string(_ element: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    private func element(_ text: String, in host: NSView) -> NSObject? {
        tree(host).first { node in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { string(node, $0) == text }
        }
    }

    private func frame(_ element: NSObject) -> CGRect? {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let boxed = element.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return boxed.rectValue
    }
}
