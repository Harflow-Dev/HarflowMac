import Combine
import Foundation
import HfCommon
import HfRepository
import Mockable
import MonitorCore
import SwiftUI

// MARK: - GroupPresentationUseCase

@Mockable
protocol GroupPresentationUseCase: Sendable {
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
}

final class GroupPresentationViewRepository: GroupPresentationUseCase {
    private let taskListRepository: any TaskListRepository

    init(taskListRepository: any TaskListRepository) { self.taskListRepository = taskListRepository }

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
}

// MARK: - GroupMembershipPresentation

struct GroupMembershipPresentation: Equatable, Sendable {
    let conversations: [[String]]
    let parents: [String: String]
    let harnesses: [String: Harness]

    struct Harness: Equatable, Hashable, Sendable {
        let session: String
        let backend: String
    }

    nonisolated static func build(name: String, tasks: [TaskInfo]) -> Self {
        let group = Lineage.sections(tasks).parallel.first { $0.name == name }
        let conversations = WorkflowOrchestratorConversation.conversations(group?.conversations.flatMap(\.members) ?? [])
        let parents = Dictionary(tasks.compactMap { task in
            (task.continuationOfTaskID ?? task.parentTaskID).map { (task.taskID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let harnesses = Dictionary(tasks.compactMap { task -> (String, Harness)? in
            guard let session = task.sessionID, !session.isEmpty, task.backend != "unknown" else { return nil }
            return (task.taskID, Harness(session: session, backend: task.backend))
        }, uniquingKeysWith: { first, _ in first })
        return Self(conversations: conversations.map { $0.members.map(\.taskID) }, parents: parents, harnesses: harnesses)
    }
}

// MARK: - GroupPresentationViewModel

@MainActor
protocol GroupPresentationViewModel: ViewModel {
    associatedtype Detail: TaskDetailViewModel
    associatedtype Parallel: ParallelViewModel
    var detailVM: Detail? { get }
    var parallelVM: Parallel? { get }
    var activityState: ParallelColumnUIState { get }
    var detailIdentity: String? { get }
    var hasPromotedActivity: Bool { get }
    /// True once the group's membership has been classified at least once; before that the loading skeleton shows.
    var isClassified: Bool { get }
    func didAppear()
    func didDisappear()
}

// MARK: - GroupPresentationVM

/// Owns the selected group's renderer for its visible lifetime, independent of task status.
@Observable
@MainActor
final class GroupPresentationVM: GroupPresentationViewModel {
    private(set) var detailVM: TaskDetailVM?
    private(set) var parallelVM: ParallelVM?
    private(set) var detailIdentity: String?
    private(set) var activityState = ParallelColumnUIState()
    private(set) var hasPromotedActivity = false
    private(set) var isClassified = false
    @ObservationIgnored private let groupName: String
    /// The group's top bar: this VM shows the loading content until the group is classified, then hands the same writer
    /// identity to the Parallel VM (several conversations) or clears it (one conversation or none).
    @ObservationIgnored private let routing: (any ParallelRouting)?
    @ObservationIgnored private var topBarTag: TaskTopBarHolder.Tag { TaskTopBarHolder.Tag(writer: ObjectIdentifier(self), subject: .group(groupName)) }
    @ObservationIgnored private let useCase: any GroupPresentationUseCase
    @ObservationIgnored private let makeDetail: (String) -> TaskDetailVM
    @ObservationIgnored private let makeParallel: () -> ParallelVM
    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var membership: GroupMembershipPresentation?
    @ObservationIgnored private var detailMembers: Set<String> = []
    @ObservationIgnored private var detailHarnesses: Set<GroupMembershipPresentation.Harness> = []

    init(groupName: String, useCase: any GroupPresentationUseCase, routing: (any ParallelRouting)? = nil,
         makeDetail: @escaping (String) -> TaskDetailVM, makeParallel: @escaping () -> ParallelVM) {
        self.groupName = groupName
        self.routing = routing
        self.useCase = useCase
        self.makeDetail = makeDetail
        self.makeParallel = makeParallel
    }

    func didAppear() {
        guard !didSubscribe else { return }
        didSubscribe = true
        routing?.publishTopBar(GroupTopBarContent(title: groupName, badge: nil, meta: nil, isLoading: true), tag: topBarTag)
        routing?.activateTopBar(tag: topBarTag)
        subscription = useCase.tasksPublisher()
.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in self?.classify(tasks) }
    }

    func didDisappear() {
        guard didSubscribe else { return }
        didSubscribe = false
        isClassified = false
        releaseTopBar()
        generation &+= 1
        subscription = nil
        worker?.cancel()
        worker = nil
        detailVM?.didDisappear()
        parallelVM?.didDisappear()
        detailVM = nil
        parallelVM = nil
        detailIdentity = nil
        detailMembers = []
        detailHarnesses = []
        membership = nil
        activityState = ParallelColumnUIState()
        hasPromotedActivity = false
    }

    private func classify(_ tasks: [TaskInfo]) {
        generation &+= 1
        let revision = generation
        let name = groupName
        worker?.cancel()
        let computation = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return GroupMembershipPresentation?.none }
            let result = GroupMembershipPresentation.build(name: name, tasks: tasks)
            return Task.isCancelled ? nil : result
        }
        worker = Task { [weak self] in
            let result = await withTaskCancellationHandler { await computation.value } onCancel: { computation.cancel() }
            guard let self, didSubscribe, generation == revision, let result else { return }
            worker = nil
            guard membership != result else { return }
            membership = result
            apply(result)
        }
    }

    private func releaseTopBar() {
        routing?.deactivateTopBar(tag: topBarTag)
        routing?.clearTopBar(tag: topBarTag)
    }

    /// An empty group keeps its own name in the bar (no badge, no meta) under the loading content's tag; one conversation
    /// releases the bar to the task screen; several are taken over by the Parallel VM under the same tag.
    private func settleTopBar(conversationCount: Int) {
        if conversationCount == 0 {
            routing?.publishTopBar(GroupTopBarContent(title: groupName, badge: nil, meta: nil, isLoading: false), tag: topBarTag)
            // A group that went from one conversation to none was released: ask to be shown again.
            routing?.activateTopBar(tag: topBarTag)
        } else if conversationCount == 1 {
            releaseTopBar()
        }
    }

    private func apply(_ value: GroupMembershipPresentation) {
        isClassified = true
        // Promotion is one-way until the selected group is torn down, retaining visited lanes.
        if parallelVM != nil { return }
        settleTopBar(conversationCount: value.conversations.count)
        if value.conversations.count > 1 {
            let parallel = makeParallel()
            // The Parallel VM writes under this VM's identity, so the loading content is replaced in place.
            parallel.topBarWriter = ObjectIdentifier(self)
            if let detailVM, let snapshot = detailVM.exportConversationActivity() {
                parallel.seedConversationActivity(snapshot, state: activityState)
                hasPromotedActivity = true
            }
            detailVM?.didDisappear()
            parallelVM = parallel
            detailVM = nil
            detailIdentity = nil
        } else if let members = value.conversations.first, let id = members.first {
            let nextMembers = Set(members)
            let retained = detailMembers.union(detailVM?.conversationMembers.map(\.taskID) ?? [])
            var connected = !retained.isDisjoint(with: nextMembers)
            for member in members {
                guard let harness = value.harnesses[member], detailHarnesses.contains(harness) else { continue }
                var parent = value.parents[member]
                var visited: Set<String> = []
                while let id = parent, visited.insert(id).inserted {
                    if retained.contains(id) { connected = true; break }
                    parent = value.parents[id]
                }
            }
            if detailVM == nil || !connected {
                detailVM?.didDisappear()
                activityState = ParallelColumnUIState()
                detailIdentity = id
                detailVM = makeDetail(id)
            } else {
                detailVM?.retainConversationIdentity(through: id)
            }
            detailMembers = nextMembers
            detailHarnesses = Set(members.compactMap { value.harnesses[$0] })
        } else {
            detailVM?.didDisappear()
            detailVM = nil
            detailIdentity = nil
            detailMembers = []
        }
    }
}

// MARK: - GroupPresentationView

struct GroupPresentationView<VM: GroupPresentationViewModel>: View {
    @State var viewModel: VM
    @Environment(\.viewEvent) private var viewEvent

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        ZStack {
            if let parallel = viewModel.parallelVM {
                ParallelView(parallel, initiallyPrepared: viewModel.hasPromotedActivity)
            } else if let detail = viewModel.detailVM {
                TaskDetailView(detail, activityState: viewModel.activityState, transcriptStyle: .transcript).id(viewModel.detailIdentity)
            } else if viewModel.isClassified {
                ParallelEmptyGroupText()
                    .parallelGroupToolbar(.init(isEmpty: true), onViewPrompt: {}, onCancelAll: {})
            } else {
                ParallelLoadingContent(laneCount: ParallelLoadingSkeleton.defaultLaneCount)
            }
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
@Observable @MainActor
private final class GroupPresentationPreviewVM: GroupPresentationViewModel {
    var detailVM: TaskDetailViewModelMock?
    var parallelVM: ParallelViewModelMock? = ParallelViewModelMock()
    var activityState = ParallelColumnUIState()
    var detailIdentity: String?
    var hasPromotedActivity = false
    var isClassified = true
    func didAppear() {}
    func didDisappear() {}
}

#Preview("Group membership") {
    GroupPresentationView(GroupPresentationPreviewVM())
}
#endif
