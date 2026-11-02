import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - WorkflowScreenLayoutTests

@MainActor @Suite(.serialized) struct WorkflowScreenLayoutTests {
    @Test func givenBuilderTaskEmbeddedInEditor_whenRendered_thenItsTaskComposerHasNoDuplicateGlobalComposer() async throws {
        // given
        let vm = WorkflowPreview.make()
        defer { vm.didDisappear() }
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(String(repeating: "a", count: 32)),
            "kind": .string("builder"), "status": .string("running"), "builder_draft": .object(vm.definition),
            "activations": .array([.object(["role": .string("builder"), "tasks": .array([
                .object(["task_id": .string("builder-task")])])])])])
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { _, _ in
            AnyView(Text("Embedded builder Activity").accessibilityIdentifier("embedded-builder-activity"))
        }), size: CGSize(width: 1200, height: 800))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("embedded-builder-activity") != nil }
        // then
        #expect(!fixture.hasElement(containing: Self.composerLabel))
    }

    private static let composerLabel = "Message the workflow builder"
    private nonisolated static let windowSizes = [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)]

    private func builderRun(_ vm: WorkflowVM, taskID: String?) -> WorkflowRunModel {
        var raw: [String: JSONValue] = ["workflow_run_id": .string(String(repeating: "b", count: 32)),
            "kind": .string("builder"), "status": .string("running"), "builder_draft": .object(vm.definition)]
        if let taskID {
            raw["activations"] = .array([.object(["role": .string("builder"), "tasks": .array([.object(["task_id": .string(taskID)])])])])
        }
        return WorkflowRunModel(raw: raw)
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenEditorWithNoRunSelected_whenHosted_thenNoComposerAndOnlyTheStepTrayIsBelowTheCanvas(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowPreview.make()
        defer { vm.didDisappear() }
        #expect(vm.selectedRun == nil)
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.canvasScroll != nil }
        // then
        #expect(!fixture.hasElement(containing: Self.composerLabel))
        let canvas = try #require(fixture.canvasScroll)
        let frame = canvas.convert(canvas.bounds, to: nil)
        let content = fixture.window.contentLayoutRect
        let tray = try #require(fixture.element("Workflow nodes"))
        let trayFrame = try #require(fixture.frame(tray))
        // The tray's accessibility frame ends at the validation row's text, inside its vertical padding.
        #expect(abs(trayFrame.minY - (content.minY + HfRadius.Metrics.spacing12 + HfRadius.Metrics.spacing6)) < 2,
                "The step tray must sit at the bottom edge with only its own padding and no reserved footer")
        #expect(frame.minY >= trayFrame.maxY - 1, "The canvas must end above the step tray")
    }

    @Test
    func givenOptInCaptureDirectory_whenWorkflowEditorIsHosted_thenRecordsLayoutAndStablePixels() async throws {
        guard let directory = try layoutCaptureDirectory() else { return }
        let cases: [(String, CGSize, ColorScheme)] = [
            ("cold-light-1000x620", CGSize(width: 1000, height: 620), .light),
            ("cold-dark-1000x620", CGSize(width: 1000, height: 620), .dark),
            ("cold-light-1440x900", CGSize(width: 1440, height: 900), .light),
            ("cold-dark-1440x900", CGSize(width: 1440, height: 900), .dark),
            ("warm-light-1000x620", CGSize(width: 1000, height: 620), .light)
        ]
        var order: [String] = []
        for (name, size, appearance) in cases {
            try await captureLayoutCase(name: name, size: size, appearance: appearance, directory: directory)
            order.append(name)
            try writeLayoutJSON(["caseOrder": order], to: directory.appendingPathComponent("case-order.json"))
        }
    }

    private func layoutCaptureDirectory() throws -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["HARFLOW_S02_LAYOUT_CAPTURE_DIR"] else { return nil }
        guard raw.hasPrefix("/"), !raw.split(separator: "/").contains("..") else {
            throw NSError(domain: "WorkflowScreenLayoutDiagnostic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capture directory must be an absolute canonical path"])
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        let path = url.standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let scratchRoot = URL(fileURLWithPath: "/private/tmp/harflow-s02-resume", isDirectory: true).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let repository = (0 ..< 7).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }.path
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().standardizedFileURL.path == path,
              raw.hasPrefix("/private/tmp/harflow-s02-resume/"), path.hasPrefix(scratchRoot + "/"), path != scratchRoot,
              !path.hasPrefix(home + "/"), !path.hasPrefix(repository + "/"),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else {
            throw NSError(domain: "WorkflowScreenLayoutDiagnostic", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Capture directory must be an owned mode-0700 directory under the dedicated S02 scratch root"])
        }
        return url
    }

    private func captureLayoutCase(name: String, size: CGSize, appearance: ColorScheme, directory: URL) async throws {
        let createdAt = ProcessInfo.processInfo.systemUptime, vm = WorkflowPreview.make()
        var checkpoints: [[String: Any]] = [validationCheckpoint(vm, label: "vmCreated", createdAt: createdAt)]
        defer { vm.didDisappear() }
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }

        // Match the original guarded test's first settle point exactly.
        await fixture.settle { fixture.canvasScroll != nil }
        _ = fixture.hasElement(containing: Self.composerLabel)
        let canvas = try #require(fixture.canvasScroll)
        let frame = canvas.convert(canvas.bounds, to: nil)
        let content = fixture.window.contentLayoutRect
        let tray = try #require(fixture.element("Workflow nodes"))
        let trayFrame = try #require(fixture.frame(tray))
        let originalOperands: [String: Any] = [
            "nativeCanvasMinY": frame.minY, "trayMinY": trayFrame.minY, "trayMaxY": trayFrame.maxY,
            "expectedBottomPadding": HfRadius.Metrics.spacing12 + HfRadius.Metrics.spacing6,
            "contentMinY": content.minY, "trayAsAsserted": rectString(trayFrame)
        ]
        let firstGeometry = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
        checkpoints.append(validationCheckpoint(vm, label: "firstSettle", createdAt: createdAt))
        try #require(!fixture.trayRowScrolls().isEmpty, "The workflow node tray row did not render")
        let firstImage = try cacheLayoutBitmap(fixture.host, to: directory.appendingPathComponent(name + "-first.png"))
        let afterCaptureGeometry = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
        checkpoints.append(validationCheckpoint(vm, label: "afterFirstCapture", createdAt: createdAt))

        let stability = try observeStableLayout(fixture: fixture, canvas: canvas, tray: tray, initial: afterCaptureGeometry)
        #expect(stability.reached, "Workflow layout did not remain unchanged for three runloop turns within 3 seconds: \(name)")

        let stablePreCaptureGeometry = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
        checkpoints.append(validationCheckpoint(vm, label: "beforeStableCapture", createdAt: createdAt))
        let captureBounds = fixture.host.bounds
        let stableImage = try cacheLayoutBitmap(fixture.host, to: directory.appendingPathComponent(name + "-stable.png"))
        let afterStableCapture = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
        checkpoints.append(validationCheckpoint(vm, label: "afterStableCapture", createdAt: createdAt))
        var report: [String: Any] = [
            "case": name, "requestedSizePoints": ["width": size.width, "height": size.height], "appearance": appearance == .dark ? "dark" : "light",
            "originalFirstSettleOperands": originalOperands, "firstSettleGeometry": firstGeometry, "geometryBeforeStableCapture": stablePreCaptureGeometry,
            "geometryAfterFirstCapture": afterCaptureGeometry, "geometryAfterStableCapture": afterStableCapture, "stable": stability.reached,
            "stabilityIterations": stability.iterations, "stabilityElapsedSeconds": stability.elapsed,
            "bitmapCoordinateMapping": bitmapMapping(fixture: fixture, bounds: captureBounds, bitmap: stableImage),
            "firstBitmap": ["pixelsWide": firstImage.width, "pixelsHigh": firstImage.height], "stableBitmap": ["pixelsWide": stableImage.width,
            "pixelsHigh": stableImage.height]
        ]
        report["validationCheckpoints"] = checkpoints
        report["validationIDChanges"] = validationIDChanges(checkpoints)
        try writeLayoutJSON(report, to: directory.appendingPathComponent(name + ".json"))
        try await captureValidatedLayout(vm: vm, surface: (fixture, canvas, tray), output: (createdAt, name, directory),
                                         report: &report, checkpoints: &checkpoints)
    }

    private func bitmapMapping(fixture: RedesignHost, bounds: CGRect, bitmap: (width: Int, height: Int)) -> [String: Any] {
        ["pixelsWide": bitmap.width, "pixelsHigh": bitmap.height,
         "pixelsPerPointX": Double(bitmap.width) / bounds.width, "pixelsPerPointY": Double(bitmap.height) / bounds.height,
         "hostIsFlipped": fixture.host.isFlipped, "capturedHostBounds": rectString(bounds),
         "hostBoundsInWindow": rectString(fixture.host.convert(bounds, to: nil)),
         "rowConvention": "Convert window points to host coordinates first. PNG row zero is the top row.",
         "rowFormula": "flipped: (hostY - bounds.minY) * pixelsPerPointY; unflipped: (bounds.maxY - hostY) * pixelsPerPointY",
         "renderingLimitations": "NSView cacheDisplay captures the hosted view; window material composition may differ from the app."]
    }

    private func validationSucceeded(_ vm: WorkflowVM) -> Bool {
        vm.selectedRun == nil && vm.validationMessage == nil && vm.validatedDefinition == vm.effectiveDefinition
    }

    private func validationCheckpoint(_ vm: WorkflowVM, label: String, createdAt: TimeInterval) -> [String: Any] {
        ["checkpoint": label, "elapsedSinceVMCreationSeconds": ProcessInfo.processInfo.systemUptime - createdAt,
         "selectedRunIsNil": vm.selectedRun == nil, "message": vm.validationMessage.map { $0 as Any } ?? NSNull(),
         "validatedDefinitionPresent": vm.validatedDefinition != nil, "validatedDefinitionMatchesEffective": vm.validatedDefinition == vm.effectiveDefinition,
         "validationID": vm.validationID.uuidString, "validationTaskReferencePresent": vm.validationTask != nil,
         "validationSuspended": vm.validationSuspended, "validationSucceeded": validationSucceeded(vm), "showsRunSheet": vm.showsRunSheet,
         "launchPreviewPresent": vm.launchPreview != nil,
         "launchPreviewMessage": vm.launchPreviewMessage.map { $0 as Any } ?? NSNull(), "launchPreviewID": vm.launchPreviewID.uuidString,
         "launchPreviewTaskReferencePresent": vm.launchPreviewTask != nil,
         "launchPreviewRendering": "Launch preview readiness/loading/error is rendered only in the run sheet; editor cases keep that sheet closed.",
         "taskReferenceInterpretation": "Task reference presence does not establish pending work or completion."]
    }

    private static let validatedHint = "Drag nodes onto the canvas; connect their dots."

    private func validatedHintIsRendered(_ vm: WorkflowVM, fixture: RedesignHost) -> Bool {
        validationSucceeded(vm) && vm.editorConflict == nil && fixture.element(Self.validatedHint) != nil
    }

    private func renderedStatusEvidence(_ vm: WorkflowVM, fixture: RedesignHost) throws -> [String: Any] {
        let checking = fixture.descendants.flatMap { fixture.elements(in: $0) }.first { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(object, $0)?.contains("Checking workflow…") == true
            }
        }
        let hint = fixture.element(Self.validatedHint)
        return ["checking": try statusElementEvidence(checking, fixture: fixture), "hint": try statusElementEvidence(hint, fixture: fixture),
                "editorConflictPresent": vm.editorConflict != nil, "hintFenceSatisfied": validatedHintIsRendered(vm, fixture: fixture)]
    }

    private func statusElementEvidence(_ element: NSObject?, fixture: RedesignHost) throws -> [String: Any] {
        guard let element else { return ["present": false, "frameInWindow": NSNull()] }
        return ["present": true, "frameInWindow": rectString(try #require(fixture.frame(element)))]
    }

    private func validationIDChanges(_ checkpoints: [[String: Any]]) -> [[String: Any]] {
        checkpoints.enumerated()
.filter { index, checkpoint in
            index == 0 || checkpoint["validationID"] as? String != checkpoints[index - 1]["validationID"] as? String
        }
.map(\.element)
    }

    private func waitForSuccessfulValidation(_ vm: WorkflowVM, fixture: RedesignHost, createdAt: TimeInterval,
                                             checkpoints: inout [[String: Any]]) async throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var previous = Data()
        while true {
            let checkpoint = validationCheckpoint(vm, label: "validationWait", createdAt: createdAt)
            var comparable = checkpoint
            comparable.removeValue(forKey: "elapsedSinceVMCreationSeconds")
            let signature = try geometrySignature(comparable)
            if signature != previous { checkpoints.append(checkpoint); previous = signature }
            if validatedHintIsRendered(vm, fixture: fixture) { return "success" }
            // scheduleValidation uses this message only while its current validation is pending.
            if let message = vm.validationMessage, message != "Checking workflow…" { return "validationFailed" }
            if ProcessInfo.processInfo.systemUptime >= deadline { return "deadlineExpired" }
            await Task.yield()
            turnLayoutRunLoop(fixture)
        }
    }

    private func captureValidatedLayout(vm: WorkflowVM, surface: (fixture: RedesignHost, canvas: NSScrollView, tray: NSObject),
                                        output: (createdAt: TimeInterval, name: String, directory: URL), report: inout [String: Any],
                                        checkpoints: inout [[String: Any]]) async throws {
        let fixture = surface.fixture
        let (createdAt, name, directory) = output
        let outcome = try await waitForSuccessfulValidation(vm, fixture: fixture, createdAt: createdAt, checkpoints: &checkpoints)
        report["validationWaitOutcome"] = outcome
        report["renderedStatusAtValidationWaitEnd"] = try renderedStatusEvidence(vm, fixture: fixture)
        report["validated"] = validationSucceeded(vm)
        report["validationCheckpoints"] = checkpoints
        report["validationIDChanges"] = validationIDChanges(checkpoints)
        let reportURL = directory.appendingPathComponent(name + ".json")
        try writeLayoutJSON(report, to: reportURL)
        guard outcome == "success" else {
            #expect(outcome == "success", "Successful workflow validation was not observed: \(name), \(outcome)")
            return
        }
        let canvas = try #require(fixture.canvasScroll), tray = try #require(fixture.element("Workflow nodes"))
        let geometry = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
        checkpoints.append(validationCheckpoint(vm, label: "validationSucceeded", createdAt: createdAt))
        report["geometryAtValidationSuccess"] = geometry
        let stability = try observeStableLayout(fixture: fixture, canvas: canvas, tray: tray, initial: geometry)
        report["validatedStable"] = stability.reached
        report["validatedStabilityIterations"] = stability.iterations
        report["validatedStabilityElapsedSeconds"] = stability.elapsed
        report["geometryBeforeValidatedCapture"] = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
        report["renderedStatusBeforeValidatedCapture"] = try renderedStatusEvidence(vm, fixture: fixture)
        checkpoints.append(validationCheckpoint(vm, label: "beforeValidatedCapture", createdAt: createdAt))
        report["validated"] = validationSucceeded(vm)
        report["validationCheckpoints"] = checkpoints
        report["validationIDChanges"] = validationIDChanges(checkpoints)
        try writeLayoutJSON(report, to: reportURL)
        guard stability.reached, validatedHintIsRendered(vm, fixture: fixture) else {
            #expect(stability.reached && validatedHintIsRendered(vm, fixture: fixture), "Validated workflow geometry or rendered hint changed: \(name)")
            return
        }
        let bounds = fixture.host.bounds
        let bitmap = try cacheLayoutBitmap(fixture.host, to: directory.appendingPathComponent(name + "-validated.png"))
        report["geometryAfterValidatedCapture"] = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
        report["renderedStatusAfterValidatedCapture"] = try renderedStatusEvidence(vm, fixture: fixture)
        checkpoints.append(validationCheckpoint(vm, label: "afterValidatedCapture", createdAt: createdAt))
        report["validatedBitmapCoordinateMapping"] = bitmapMapping(fixture: fixture, bounds: bounds, bitmap: bitmap)
        report["validationCheckpoints"] = checkpoints
        report["validationIDChanges"] = validationIDChanges(checkpoints)
        try writeLayoutJSON(report, to: reportURL)
    }

    private func observeStableLayout(fixture: RedesignHost, canvas: NSScrollView, tray: NSObject,
                                     initial: [String: Any]) throws -> (reached: Bool, iterations: Int, elapsed: TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime, deadline = start + 3
        var previous = try geometrySignature(initial)
        var consecutiveTurns = 0
        var iterations = 0
        while ProcessInfo.processInfo.systemUptime < deadline, consecutiveTurns < 3 {
            turnLayoutRunLoop(fixture)
            iterations += 1
            let current = try layoutGeometry(fixture: fixture, canvas: canvas, tray: tray)
            let signature = try geometrySignature(current)
            if signature == previous { consecutiveTurns += 1 } else { consecutiveTurns = 0 }
            previous = signature
        }
        return (consecutiveTurns >= 3, iterations, ProcessInfo.processInfo.systemUptime - start)
    }

    private func turnLayoutRunLoop(_ fixture: RedesignHost) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()
    }

    private func layoutGeometry(fixture: RedesignHost, canvas: NSScrollView, tray: NSObject) throws -> [String: Any] {
        let clip = canvas.contentView
        let window = fixture.window
        let trayAsAsserted = try #require(fixture.frame(tray))
        let accessibilityScreenFrame: CGRect
        if let accessible = tray as? any NSAccessibilityProtocol {
            accessibilityScreenFrame = accessible.accessibilityFrame()
        } else {
            try #require(tray.responds(to: NSSelectorFromString("accessibilityFrame")))
            accessibilityScreenFrame = try #require(tray.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        }
        let rows = fixture.trayRowScrolls().enumerated().map { index, scroll in
            ["index": index, "frameInWindow": rectString(scroll.convert(scroll.bounds, to: nil)),
             "clipFrameInWindow": rectString(scroll.contentView.convert(scroll.contentView.bounds, to: nil)),
             "documentFrame": rectString(scroll.documentView?.frame ?? .zero),
             "contentInsets": String(describing: scroll.contentInsets), "borderType": String(describing: scroll.borderType),
             "horizontalScrollerFrame": rectString(scroll.horizontalScroller?.frame ?? .zero),
             "verticalScrollerFrame": rectString(scroll.verticalScroller?.frame ?? .zero)] as [String: Any]
        }
        return [
            "windowFrame": rectString(window.frame), "windowScreenFrame": rectString(window.screen?.frame ?? .zero),
            "windowScreenVisibleFrame": rectString(window.screen?.visibleFrame ?? .zero), "backingScaleFactor": window.backingScaleFactor,
            "contentLayoutRect": rectString(window.contentLayoutRect), "contentViewFrame": rectString(try #require(window.contentView).frame),
            "contentViewBounds": rectString(try #require(window.contentView).bounds), "hostBounds": rectString(fixture.host.bounds),
            "hostIsFlipped": fixture.host.isFlipped,
            "canvasFrameInWindow": rectString(canvas.convert(canvas.bounds, to: nil)), "canvasBounds": rectString(canvas.bounds),
            "canvasClipFrameInWindow": rectString(clip.convert(clip.bounds, to: nil)), "canvasClipBounds": rectString(clip.bounds),
            "canvasContentInsets": String(describing: canvas.contentInsets), "canvasBorderType": String(describing: canvas.borderType),
            "canvasHorizontalScrollerFrame": rectString(canvas.horizontalScroller?.frame ?? .zero),
            "canvasVerticalScrollerFrame": rectString(canvas.verticalScroller?.frame ?? .zero),
            "trayAsAsserted": rectString(trayAsAsserted), "originalAssertionOperands": [
                "nativeCanvasMinY": canvas.convert(canvas.bounds, to: nil).minY, "trayMinY": trayAsAsserted.minY, "trayMaxY": trayAsAsserted.maxY,
                "expectedBottomPadding": HfRadius.Metrics.spacing12 + HfRadius.Metrics.spacing6, "contentMinY": window.contentLayoutRect.minY
            ],
            "trayAXRawScreenFrame": rectString(accessibilityScreenFrame),
            "trayAXFrameInWindow": rectString(window.convertFromScreen(accessibilityScreenFrame)), "trayRowScrolls": rows
        ]
    }

    private func rectString(_ rect: CGRect) -> String { NSStringFromRect(rect) }

    private func geometrySignature(_ geometry: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
    }

    private func cacheLayoutBitmap(_ view: NSView, to url: URL) throws -> (width: Int, height: Int) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "WorkflowScreenLayoutDiagnostic", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate size-aware hosted-view bitmap"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WorkflowScreenLayoutDiagnostic", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode hosted-view bitmap as PNG"])
        }
        try data.write(to: url, options: .atomic)
        return (bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    private func writeLayoutJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenBuilderRunAwaitingItsTask_whenHosted_thenNoComposerAndStartingLabelIsShown(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowPreview.make()
        defer { vm.didDisappear() }
        vm.selectedRun = builderRun(vm, taskID: nil)
        #expect(vm.selectedRun?.builderTaskID == nil)
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { _, _ in AnyView(Text("unexpected")) }).preferredColorScheme(appearance),
                                   size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Starting workflow builder…") != nil }
        // then
        #expect(fixture.element("Starting workflow builder…") != nil)
        #expect(fixture.element("unexpected") == nil)
        #expect(!fixture.hasElement(containing: Self.composerLabel))
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenBuilderRunWithTaskAndInjectedView_whenHosted_thenInjectedViewIsShownWithoutOuterComposer(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowPreview.make()
        defer { vm.didDisappear() }
        vm.selectedRun = builderRun(vm, taskID: "builder-task")
        #expect(vm.selectedRun?.builderTaskID == "builder-task")
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { taskID, _ in
            AnyView(Text("Embedded \(taskID)").accessibilityIdentifier("embedded-builder-activity"))
        }).preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("embedded-builder-activity") != nil }
        // then
        #expect(fixture.element("embedded-builder-activity") != nil)
        #expect(fixture.element("Starting workflow builder…") == nil)
    }

    @Test
    func givenLongLoadedRun_whenContentChangesAndWindowResizes_thenNavigationMinimumStaysStable() async throws {
        // given
        _ = NSApplication.shared
        let vm = WorkflowPreview.make(run: true)
        var raw = try #require(vm.selectedRun?.raw)
        raw["status"] = .string("cancelled")
        raw["decisions"] = .array([.object(["reason": .string(String(repeating: "A recent workflow decision explains the next branch. ", count: 12))])])
        raw["pending"] = .array((0 ..< 3).map { _ in .object(["decision_attempts": .number(1)]) })
        raw["prompt"] = .string(String(repeating: "A very long original request with specifications.\n", count: 20))
        raw["tasks"] = longChecklist()
        raw["technical_plan"] = .string("The final technical plan remains reachable below the checklist.")
        raw["activations"] = .array((0 ..< 6).map { .object([
            "invocation": .object(["child_workflow_run_id": .string("child-\($0)"), "workflow_name": .string("Child workflow \($0)")])
        ]) })
        vm.selectedRun = WorkflowRunModel(raw: raw)
        #expect(vm.selectedRun?.childRunIDs.count == 6)
        vm.selectedNodeID = try #require(vm.nodes.first?.id)
        #expect(vm.selectedNode != nil)
        let fixture = RedesignHost(NavigationSplitView {
            Text("Sidebar top").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } detail: { WorkflowView(vm) }.frame(minWidth: 1000, minHeight: 620), size: CGSize(width: 2210, height: 864))
        let host = fixture.host
        defer { fixture.close() }
        // when
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // The native fixture owns updates; prevent the preview's automatic polling replacing them.
        vm.didDisappear()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        #expect(host.fittingSize.height == 620)
        #expect(host.intrinsicContentSize.height == 620)
        let compactPanes = try #require(descendants(of: host).compactMap { $0 as? NSSplitView }.last { $0.isVertical })
        for status in ["cancelled", "running"] {
            raw["status"] = .string(status)
            vm.selectedRun = WorkflowRunModel(raw: raw)
            await waitUntil {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                return compactPanes.bounds.height > host.bounds.height - 200
            }
            #expect(vm.selectedRun?.status == status)
            try assertLoadedViewport(compactPanes, in: fixture)
        }
        // when
        raw["status"] = .string("needs_attention")
        raw["pending"] = .array((0 ..< 80).map { _ in .object(["decision_attempts": .number(1)]) })
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        #expect(host.fittingSize.height == 620)
        #expect(host.intrinsicContentSize.height == 620)
        // when
        fixture.window.setContentSize(CGSize(width: 1000, height: 620))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        #expect(host.fittingSize.height == 620)
        #expect(host.intrinsicContentSize.height == 620)
        #expect(fixture.window.contentLayoutRect.height == 620)
        let expand = try #require(fixture.element("Expand summary"))
        #expect(fixture.press(expand))
        await fixture.settle { fixture.element("Collapse summary") != nil }
        try assertAccessiblePanes(in: host)
    }

    private func assertLoadedViewport(_ split: NSSplitView, in fixture: RedesignHost) throws {
        let panes = split.convert(split.bounds, to: nil)
        let content = fixture.window.contentLayoutRect
        #expect(!fixture.hasElement(containing: Self.composerLabel),
                "A workflow run must not show the create/edit builder composer below its canvas")
        #expect(panes.height > fixture.host.bounds.height - 200,
                "Compact status must retain the full run viewport without a global composer")
        #expect(abs(panes.minY - content.minY - 36) < 1,
                "Only the intrinsic collapsed summary should separate the panes from the bottom edge")
        #expect(panes.minY >= content.minY - 1 && panes.maxY <= content.maxY + 1)
    }

    private func assertAccessiblePanes(in host: NSView) throws {
        let split = try #require(descendants(of: host).compactMap { $0 as? NSSplitView }.last { $0.isVertical })
        let paneBounds = host.convert(split.bounds, from: split)
        #expect(paneBounds.minY >= -1)
        #expect(paneBounds.maxY <= host.bounds.maxY + 1)
        #expect(split.arrangedSubviews.allSatisfy { $0.bounds.height > 0 })
        let inspectorPane = try #require(split.arrangedSubviews.last)
        let inspector = try #require(descendants(of: inspectorPane).compactMap { $0 as? NSScrollView }.first)
        let diagnostics = try #require(descendants(of: host).compactMap { $0 as? NSScrollView }.first { !$0.isDescendant(of: split) })
        for scroll in [diagnostics, inspector] {
            #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 20)
            let document = try #require(scroll.documentView)
            let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? bottom : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            let visible = scroll.documentVisibleRect
            #expect(document.isFlipped ? abs(visible.maxY - document.bounds.maxY) < 2 : abs(visible.minY) < 2)
        }
    }

    private func longChecklist() -> JSONValue {
        .array((0 ..< 19).map { .object([
            "id": .string("task-\($0)"), "title": .string("Long checklist task \($0)"),
            "description": .string(String(repeating: "detail\n", count: 3))
        ]) })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test(arguments: ["failure", "preparing", "loaded"], [
        CGSize(width: 1440, height: 1440), CGSize(width: 2210, height: 864), CGSize(width: 1000, height: 620)
    ])
    func givenWorkflowState_whenLaidOutAndThenLoaded_thenHeaderStaysAtTop(_ kind: String, _ size: CGSize) async throws {
        // given
        _ = NSApplication.shared
        let state = ScreenLayoutState(kind: kind)
        let host = NSHostingView(rootView: ScreenLayoutFixture(state: state))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.probe?.bounds.height == 90 }
        let probe = try #require(state.probe)
        let before = host.convert(probe.bounds, from: probe)
        let top = host.isFlipped ? before.minY : host.bounds.height - before.maxY
        // then
        #expect(abs(top) < 1, "Header was centered at \(top) instead of pinned to the top")
        state.kind = "loaded"
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let after = host.convert(probe.bounds, from: probe)
        #expect(abs(after.minY - before.minY) < 1)
        #expect(abs(after.height - before.height) < 1)
    }
}

// MARK: - ScreenLayoutState

@MainActor @Observable private final class ScreenLayoutState {
    var kind: String
    var probe: NSView?
    init(kind: String) { self.kind = kind }
}

// MARK: - ScreenLayoutFixture

private struct ScreenLayoutFixture: View {
    let state: ScreenLayoutState
    var body: some View {
        WorkflowScreenLayout {
            Text("Workflow header / Graph / Parallel")
.frame(maxWidth: .infinity)
.frame(height: 90)
                .background(HeaderGeometryProbe { state.probe = $0 })
        } content: {
            switch state.kind {
            case "failure": ContentUnavailableView("Workflow could not be loaded", systemImage: "exclamationmark.triangle")
            case "preparing": WorkflowLoadingView(isRun: true)
            default: Color.clear
            }
        }
    }
}

// MARK: - HeaderGeometryProbe

private struct HeaderGeometryProbe: NSViewRepresentable {
    let didCreate: (NSView) -> Void
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        didCreate(view)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

extension RedesignHost {
    /// Whether any accessibility element's label, title or value contains `text`.
    func hasElement(containing text: String) -> Bool {
        descendants.flatMap { elements(in: $0) }.contains { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { string(object, $0)?.contains(text) == true }
        }
    }
}
