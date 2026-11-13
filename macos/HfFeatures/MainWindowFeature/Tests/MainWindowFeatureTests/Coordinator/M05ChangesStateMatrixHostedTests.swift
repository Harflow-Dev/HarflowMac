import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - M05ChangesStateMatrixHostedTests

/// Native evidence for the fifteen Changes states of HarflowDesign `v2/scripts/screens-m05-proposal.js` (pin 4ff7d83), each in
/// the production shell with a real standalone `TaskDetailVM` whose `readChanges` is scripted. The built presentation
/// (`TaskChangesPresentationBuilder`) is the oracle for what the tab should show; the assertions then check the window's
/// accessibility tree for it. They state what native renders and do not establish pixel fidelity.
@MainActor
@Suite(.serialized)
struct M05ChangesStateMatrixHostedTests {
    nonisolated static let states = M05StateTable.ids(.changes)

    @Test(arguments: states, [false, true])
    func givenApprovedChangesState_whenHostedInBothSizes_thenNativeStateRenders(state: String, dark: Bool) async throws {
        // given / when / then
        try await M05MatrixRunner.run(Self.spec(state), dark: dark)
    }

    // MARK: Recipes

    static func spec(_ state: String) -> M05MatrixRunner.Spec {
        switch state {
        case "changes-single": listing(state, { try ChangesJSON.availableListing() }, verifyListing: single)
        case "changes-multi": listing(state, { try completeMultiSnapshot() }, verifyListing: multi)
        case "changes-multi-limited": listing(state, { try ChangesPaneMocks.multiSnapshot() }, verifyListing: multiLimited)
        case "changes-same-path": listing(state, { try samePathSnapshot() }, verifyListing: samePath)
        case "changes-row-states": listing(state, { try rowStatesSnapshot() }, verifyListing: rowStates)
        case "changes-incomplete": listing(state, { try ChangesJSON.incomplete() }, verifyListing: incomplete)
        case "changes-not-captured": listing(state, { try notCapturedSnapshot() }, verifyListing: notCaptured)
        case "changes-unmerged": listing(state, { try unmergedSnapshot() }, verifyListing: unmerged)
        case "changes-running":
            listing(state, { try ChangesJSON.pendingRunning() }, running: true, landmark: "No changes to show while this runs") { ctx, built in
            #expect(ctx.vm.changesTabCount == nil)
            #expect(!ctx.has("No differences observed."), "running never reads as zero \(ctx.name)")
            _ = built
        }
        case "changes-zero": listing(state, { try ChangesJSON.zeroRows() }, landmark: "No differences observed.") { ctx, built in
            #expect(built.tabCount == 0)
            #expect(ctx.has("Changes, 0"), "zero count shown \(ctx.name)")
        }
        case "changes-no-repository": listing(state, { try ChangesJSON.noRepository() }, landmark: "No repository recorded") { ctx, _ in
            #expect(ctx.hasContaining("This task finished without a repository to compare."), "detail \(ctx.name)")
            #expect(ctx.vm.changesTabCount == nil)
        }
        case "changes-text": text()
        case "changes-loading": loading()
        case "changes-error":
            listing(state, { try ChangesJSON.unavailable() }, landmark: "Stored changes unavailable") { ctx, _ in
                #expect(ctx.vm.changesTabCount == nil)
                #expect(ctx.has("Retry read"), "Retry read offered \(ctx.name)")
                #expect(!ctx.has("No differences observed."))
            }
        case "changes-turns": turns()
        default: preconditionFailure("No recipe for changes state \(state)")
        }
    }

    // MARK: Shared pieces

    private static func baseConfig() -> @MainActor @Sendable (NSSize) -> TopBarIntegratedFixture.Config {
        { _ in
            var config = TopBarIntegratedFixture.Config()
            config.title = "Fix the flaky retry path in the slot release"
            config.notices = 0
            config.continuity = false
            config.openPane = true
            config.paneTab = .changes
            return config
        }
    }

    /// The listing recipe: a settled (or running) task, the pane open on Changes and `readChanges` answering `snapshot`.
    private static func listing(_ state: String, _ snapshot: @escaping () throws -> TaskChangesSnapshot, running: Bool = false,
                                landmark: String? = nil,
                                verifyListing: @escaping (M05MatrixRunner.Context, TaskChangesBuilt) throws -> Void) -> M05MatrixRunner.Spec {
        let task = running ? M05Fixtures.task(status: "running") : M05Fixtures.settled()
        let oracle = Holder()
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.changes.rawValue, state: state, config: baseConfig(), build: {
            let snapshot = try snapshot()
            oracle.built = TaskChangesPresentationBuilder.built(snapshot, taskID: M05Fixtures.taskID)
            let harness = M05Fixtures.harness(task, stubChanges: false)
            let script = ChangesReadScript(.snapshot(snapshot))
            given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
            return .init(harness: harness, retained: [script, oracle])
        }, drive: { ctx in ctx.harness.tasksSubject.send([task]) }, ready: { ctx in
            guard ctx.fixture.hasPane, let built = oracle.built else { return false }
            return ctx.vm.changesPresentation == built.presentation && (landmark.map { ctx.hasContaining($0) } ?? true)
        }, verify: { ctx in
            let built = try #require(oracle.built)
            try assertChangesPane(ctx, built: built)
            try verifyListing(ctx, built)
        })
    }

    private final class Holder { var built: TaskChangesBuilt? }

    /// What every Changes state shows: the pane on the Changes tab, the presentation the oracle built, and the tab label
    /// carrying its count only when the rule holds.
    private static func assertChangesPane(_ ctx: M05MatrixRunner.Context, built: TaskChangesBuilt) throws {
        #expect(ctx.fixture.hasPane, "pane open \(ctx.name)")
        #expect(ctx.fixture.store.selectedTab(for: TopBarIntegratedFixture.conversation) == .changes)
        #expect(ctx.vm.changesPresentation == built.presentation, "presentation matches the builder \(ctx.name)")
        #expect(ctx.vm.changesTabCount == built.tabCount, "tab count matches the builder \(ctx.name)")
        if let count = built.tabCount {
            #expect(ctx.inPane("Changes, \(count)"), "tab label with count \(ctx.name)")
        } else {
            #expect(ctx.inPane("Changes"), "tab label without a count \(ctx.name)")
            #expect(!ctx.tree.contains { ShellMatrix.label($0)?.hasPrefix("Changes, ") == true }, "no count in the tab label \(ctx.name)")
        }
    }

    /// The accessibility label a row button carries, as `ChangesRowView` builds it.
    static func rowLabel(_ row: TaskChangesRowModel) -> String {
        var parts = [row.statusWord, row.path]
        if let state = row.state { parts.append(state) }
        if let additions = row.additions { parts.append("\(additions) added") }
        if let deletions = row.deletions { parts.append("\(deletions) removed") }
        return parts.joined(separator: ", ")
    }

    // MARK: Snapshots the shared support lacks

    /// Eight complete repositories (the engine's maximum) in both scopes, so the tab count is the sum of their stored row counts.
    static func completeMultiSnapshot() throws -> TaskChangesSnapshot {
        let repositories = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"].map { name in
            ChangesJSON.repository(root: "/work/\(name)",
                                   committed: ChangesJSON.committed(rows: [
                                       ChangesJSON.row("\(name)/a.swift"), ChangesJSON.row("\(name)/b.swift", status: "added")]),
                                   working: ChangesJSON.working(rows: [ChangesJSON.row("\(name)/c.swift")]))
        }
        return try ChangesJSON.snapshot(ChangesJSON.page(repositories: repositories))
    }

    /// The same path changed in the committed range and in the working tree: two rows, never merged.
    static func samePathSnapshot() throws -> TaskChangesSnapshot {
        let repository = ChangesJSON.repository(
            committed: ChangesJSON.committed(rows: [ChangesJSON.row("src/app.py")]),
            working: ChangesJSON.working(rows: [ChangesJSON.row("src/app.py")]))
        return try ChangesJSON.snapshot(ChangesJSON.page(repositories: [repository]))
    }

    /// Binary, untracked, truncated, text omitted, cut path and not captured rows in one repository.
    static func rowStatesSnapshot() throws -> TaskChangesSnapshot {
        let committed = ChangesJSON.committed(rows: [
            ChangesJSON.row("assets/logo.png", status: "added", additions: nil, deletions: nil, binary: true, content: "binary"),
            ChangesJSON.row("big.txt", content: "truncated", reason: "file_limit", bytes: 70000),
            ChangesJSON.row("huge.txt", content: "omitted_size", reason: "task_limit", bytes: 0),
            ChangesJSON.row("cut/path", pathTruncated: true, additions: nil, deletions: nil, content: "not_captured", reason: "path_too_long"),
            ChangesJSON.row("vendor/lib", status: "submodule", additions: nil, deletions: nil, content: "not_captured", reason: "submodule")
        ])
        let working = ChangesJSON.working(rows: [
            ChangesJSON.row("notes.txt", status: "untracked", additions: nil, deletions: nil, content: "not_captured", reason: "untracked"),
            ChangesJSON.row("scratch/", status: "untracked", additions: nil, deletions: nil, content: "not_captured", reason: "untracked")
        ])
        return try ChangesJSON.snapshot(ChangesJSON.page(repositories: [ChangesJSON.repository(committed: committed, working: working)]))
    }

    /// An available capture whose scopes were not captured, with the engine's per-scope reasons.
    static func notCapturedSnapshot() throws -> TaskChangesSnapshot {
        let repository = ChangesJSON.repository(
            committed: ChangesJSON.committed(state: "not_captured", reason: "capture_missing"),
            working: ChangesJSON.working(state: "not_captured", reason: "outcome_unobserved"))
        let second = ChangesJSON.repository(
            root: "/work/beta",
            committed: ChangesJSON.committed(state: "not_captured", reason: "outcome_unobserved"),
            working: ChangesJSON.working(state: "not_captured", reason: "capture_missing"))
        return try ChangesJSON.snapshot(ChangesJSON.page(repositories: [repository, second]))
    }

    /// One repository whose working tree has unmerged state unknown and one with reported conflicts, rows still listed.
    static func unmergedSnapshot() throws -> TaskChangesSnapshot {
        let unknown = ChangesJSON.repository(
            root: "/work/alpha",
            committed: ChangesJSON.committed(rows: [ChangesJSON.row("a.swift")]),
            working: ChangesJSON.working(rows: [ChangesJSON.row("b.swift")], unmergedUnknown: true))
        let reported = ChangesJSON.repository(
            root: "/work/beta",
            committed: ChangesJSON.committed(rows: [ChangesJSON.row("c.swift")]),
            working: ChangesJSON.working(rows: [ChangesJSON.row("d.swift")], conflicts: ["d.swift"]))
        return try ChangesJSON.snapshot(ChangesJSON.page(repositories: [unknown, reported]))
    }

    // MARK: Listing verification

    private static func rows(_ built: TaskChangesBuilt) -> [TaskChangesRowModel] {
        built.document?.repositories.flatMap { $0.scopes.flatMap(\.rows) } ?? []
    }

    private static func single(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        #expect(built.tabCount != nil)
        #expect(ctx.inPane("Committed") && ctx.inPane("Working tree"), "both scopes in the pane \(ctx.name)")
        #expect(ctx.hasContaining(TaskChangesRepositoryEntry.attribution), "attribution sentence \(ctx.name)")
        let readme = try #require(rows(built).first { $0.path == "README.md" })
        #expect(ctx.has(rowLabel(readme)), "row \(rowLabel(readme)) \(ctx.name)")
    }

    private static func headers(_ ctx: M05MatrixRunner.Context) -> [(label: String, value: String)] {
        ctx.tree.compactMap { object in
            guard let value = ShellMatrix.value(object), value == "Expanded" || value == "Collapsed", let label = ShellMatrix.label(object) else { return nil }
            return (label, value)
        }
    }

    private static func multi(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        let document = try #require(built.document)
        let total = rows(built).count
        #expect(built.tabCount == total, "tab count sums the stored row counts \(ctx.name)")
        let values = headers(ctx)
        for repository in document.repositories {
            #expect(values.contains { $0.label.hasPrefix(repository.name) }, "repository header \(repository.name) \(ctx.name): \(values)")
        }
        #expect(values.first { $0.label.hasPrefix("alpha") }?.value == "Expanded", "first repository open \(ctx.name)")
        for repository in document.repositories.dropFirst() {
            #expect(values.first { $0.label.hasPrefix(repository.name) }?.value == "Collapsed", "\(repository.name) collapsed \(ctx.name)")
            #expect(repository.count != nil, "collapsed repository keeps its count")
        }
    }

    private static func multiLimited(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        let document = try #require(built.document)
        #expect(built.tabCount == nil, "a limited repository removes the tab count \(ctx.name)")
        let values = headers(ctx)
        for repository in document.repositories {
            let header = try #require(values.first { $0.label.hasPrefix(repository.name) }, "repository header \(repository.name) \(ctx.name)")
            if let count = repository.count { #expect(header.label.contains(count), "own count \(count) in \(header.label)") }
            if let tag = repository.tag { #expect(header.label.contains(tag.text), "own tag \(tag.text) in \(header.label)") }
        }
        #expect(document.repositories.contains { $0.count?.hasSuffix("+") == true || $0.tag != nil }, "a limited repository is present")
    }

    private static func samePath(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        let same = rows(built).filter { $0.path == "src/app.py" }
        #expect(same.count == 2, "two rows, never merged")
        let label = rowLabel(try #require(same.first))
        #expect(ShellMatrix.elements(label, in: ctx.window).count == 2, "both rows drawn \(ctx.name)")
        #expect(ctx.hasContaining(TaskChangesPresentationBuilder.workingTreeCaption), "working tree caption \(ctx.name)")
        #expect(built.document?.countCaption != nil, "count caption")
    }

    private static func rowStates(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        let all = rows(built)
        #expect(all.count == 7)
        for row in all {
            let label = rowLabel(row)
            let element = ctx.element(label)
            #expect(element != nil, "row \(label) \(ctx.name)")
            if row.isDimmed, let element { #expect(ShellMatrix.isEnabled(element) == false, "non-addressable row is not a control \(label)") }
        }
        #expect(all.contains { $0.isDimmed }, "a non-addressable row exists")
        for tag in ["Binary", "Name only", "Directory · name only", "Path cut · no text", "Text omitted · task limit"] {
            #expect(all.contains { $0.state == tag }, "row state \(tag) built")
        }
    }

    private static func incomplete(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        let document = try #require(built.document)
        #expect(!ctx.has("No differences observed."), "incomplete never claims no differences \(ctx.name)")
        let big = try #require(rows(built).first { $0.path == "big.txt" })
        #expect(ctx.has(rowLabel(big)), "rows read so far stay \(ctx.name)")
        if let banner = document.banner { #expect(ctx.hasContaining(banner.title), "banner \(banner.title) \(ctx.name)") }
    }

    private static func notCaptured(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        let document = try #require(built.document)
        #expect(built.tabCount == nil)
        #expect(!ctx.has("No differences observed."))
        #expect(ctx.hasContaining("Not captured"), "Not captured tags drawn \(ctx.name)")
        for repository in document.repositories {
            #expect(repository.tag?.text == "Not captured" || repository.scopes.contains { $0.tag?.text == "Not captured" }, "tag per repository or scope")
        }
    }

    private static func unmerged(_ ctx: M05MatrixRunner.Context, _ built: TaskChangesBuilt) throws {
        _ = try #require(built.document)
        #expect(ctx.hasContaining("Conflicts unknown"), "unmerged_unknown stated \(ctx.name)")
        #expect(ctx.hasContaining("Reported conflict"), "reported conflict stated \(ctx.name)")
        #expect(ctx.hasContaining("Conflicts may exist"), "advisory note \(ctx.name)")
        for row in rows(built).prefix(2) { #expect(ctx.has(rowLabel(row)), "rows still shown \(rowLabel(row))") }
    }

    // MARK: Diff, loading, error, turns

    private static func text() -> M05MatrixRunner.Spec {
        let task = M05Fixtures.settled()
        let patchBox = PatchBox()
        let listing = Holder()
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.changes.rawValue, state: "changes-text", config: baseConfig(), build: {
            let snapshot = try ChangesJSON.availableListing()
            listing.built = TaskChangesPresentationBuilder.built(snapshot, taskID: M05Fixtures.taskID)
            let harness = M05Fixtures.harness(task, stubChanges: false)
            let script = ChangesReadScript(.snapshot(snapshot))
            given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
            let patches = ChangesPatchScript()
            patchBox.script = patches
            patches.answerFromNowOn(.text(ChangesJSON.textCompleteText))
            given(harness.useCase).readChangesPatch(key: .any, selector: .any, operationIsCurrent: .any).willProduce { key, selector, fence in
                patches.serve(key, selector, fence)
            }
            return .init(harness: harness, retained: [script, patches, listing, patchBox])
        }, drive: { ctx in
            ctx.harness.tasksSubject.send([task])
            guard let built = listing.built else { return }
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.vm.changesPresentation == built.presentation }
            // The row is a real button (TaskChangesTabHostedTests presses it); selecting through the VM keeps this state independent of it.
            if let row = rows(built).first(where: { $0.path == "README.md" }), let selector = row.selector {
                await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.has(rowLabel(row)) }
                #expect(ctx.has(rowLabel(row)), "row drawn \(ctx.name)")
                ctx.vm.didSelectChangesRow(selector)
            }
        }, ready: { ctx in
            if case .diff = ctx.vm.changesDiff { return true }
            return false
        }, verify: { ctx in
            guard case .diff(let model) = ctx.vm.changesDiff else { Issue.record("no diff shown \(ctx.name)"); return }
            #expect((patchBox.script?.count ?? 0) >= 1, "the patch was read")
            #expect(model.drawnLines.contains { $0.contains("print('b')") }, "diff model holds the patch text")
            #expect(ctx.paneContains("print('b')"), "diff line drawn inside the pane \(ctx.name)")
            #expect(ctx.paneContains("Committed"), "scope header in the pane \(ctx.name)")
        }, finish: { ctx in
            // A refusal on the next read offers Retry.
            patchBox.script?.answerFromNowOn(.failure(.failed(.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "fixture"))))
            guard let built = listing.built,
                  let row = rows(built).first(where: { $0.path == "docs/guide.md" }), let selector = row.selector else { return }
            ctx.vm.didSelectChangesRow(selector)
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.paneContains("Retry") }
            #expect(ctx.paneContains("Retry"), "Retry offered inside the pane on a read failure \(ctx.name)")
        })
    }

    private static func loading() -> M05MatrixRunner.Spec {
        let task = M05Fixtures.settled()
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.changes.rawValue, state: "changes-loading", config: baseConfig(), build: {
            let harness = M05Fixtures.harness(task, stubChanges: false)
            // A reply keyed with another generation is dropped by the view model, which keeps its first-read presentation.
            let script = ChangesReadScript(.wrongKey(try ChangesJSON.availableListing()))
            given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
            return .init(harness: harness, retained: [script])
        }, drive: { ctx in ctx.harness.tasksSubject.send([task]) }, ready: { ctx in
            ctx.fixture.hasPane && ctx.hasContaining("Reading stored changes")
        }, verify: { ctx in
            #expect(ctx.vm.changesPresentation == .loading)
            #expect(ctx.vm.changesTabCount == nil)
            #expect(ctx.inPane("Changes"))
            #expect(!ctx.tree.contains { ShellMatrix.label($0)?.hasPrefix("Changes, ") == true }, "no count while reading \(ctx.name)")
            #expect(!ctx.has("No differences observed."), "no zero while reading \(ctx.name)")
        })
    }

    private static func turns() -> M05MatrixRunner.Spec {
        let current = M05Fixtures.settled()
        let earlier = M05Fixtures.settled(fields: ["task_id": .string("earlier01")])
        let listing = Holder()
        let scriptBox = ScriptBox()
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.changes.rawValue, state: "changes-turns", config: baseConfig(), build: {
            let fixtures = TaskDetailVMTests.Fixtures()
            fixtures.conversationMembersProvider.value = { _ in [earlier, current] }
            fixtures.taskProvider.value = { id in id == "earlier01" ? earlier : id == M05Fixtures.taskID ? current : nil }
            let harness = M05Fixtures.harness(current, fixtures: fixtures, stubChanges: false)
            M05Fixtures.installMember(earlier, conversation: [earlier, current], on: harness)
            let snapshot = try ChangesJSON.availableListing()
            listing.built = TaskChangesPresentationBuilder.built(snapshot, taskID: M05Fixtures.taskID)
            let script = ChangesReadScript(.snapshot(snapshot))
            scriptBox.script = script
            given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
            return .init(harness: harness, retained: [script, listing, scriptBox])
        }, drive: { ctx in ctx.harness.tasksSubject.send([earlier, current]) }, ready: { ctx in
            ctx.fixture.hasPane && ctx.vm.changesTurns != nil && listing.built.map { ctx.vm.changesPresentation == $0.presentation } == true
        }, verify: { ctx in
            let picker = try #require(ctx.vm.changesTurns, "turn picker \(ctx.name)")
            #expect(picker.options.map(\.id) == [M05Fixtures.taskID, "earlier01"], "newest first \(ctx.name)")
            #expect(picker.selectedID == M05Fixtures.taskID, "the current member is read by default")
            #expect(scriptBox.script?.calls.map(\.key.taskID) == [M05Fixtures.taskID], "only the current member was read")
            #expect(ctx.hasContaining("Turn 2 of 2"), "turn picker drawn \(ctx.name)")
        }, finish: { ctx in
            ctx.vm.didSelectChangesTurn("earlier01")
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return scriptBox.script?.calls.count == 2 }
            #expect(scriptBox.script?.calls.map(\.key.taskID) == [M05Fixtures.taskID, "earlier01"], "each turn is its own task")
        })
    }

    private final class ScriptBox { var script: ChangesReadScript? }
    private final class PatchBox { var script: ChangesPatchScript? }
}
