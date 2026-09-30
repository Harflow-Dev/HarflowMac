//
//  TaskDetailVM+Subscriptions.swift
//  MainWindowFeature
//
//  The VM's Combine subscriptions and the per-member event leases, split out of `TaskDetailVM.swift`
//  to keep it under the lint limits (redesign phase 5). Behaviour is unchanged.
//

import Combine
import Foundation
import MonitorCore

extension TaskDetailVM {

    func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.recomputeMembersAndLeases() }
            .store(in: &cancellables)

        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self else { return }
                hasListed = value
                recompute()
            }
            .store(in: &cancellables)

        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        useCase.snapshotsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in
                guard let self else { return }
                // Plan review round 1, item 3: ignore a publication that doesn't touch any member of
                // THIS conversation — `snapshots` covers every task in the system, so it changes on
                // essentially every publish; a plain `.removeDuplicates()` on the whole dictionary
                // would almost never fire and buys nothing. Before membership is known at all
                // (`conversationMembers` still empty — e.g. a snapshot arriving ahead of the
                // listing), every publication still applies, so a real change is never dropped.
                let touchesConversation = conversationMembers.isEmpty
                    || conversationMembers.contains { latestSnapshots[$0.taskID] != snapshots[$0.taskID] }
                guard touchesConversation else { return }
                latestSnapshots = snapshots
                recompute()
            }
            .store(in: &cancellables)

        useCase.busyPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                guard let self else { return }
                latestBusy = busy
                recompute()
            }
            .store(in: &cancellables)

        useCase.outcomesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomes in
                guard let self else { return }
                latestOutcomes = outcomes
                recompute()
            }
            .store(in: &cancellables)
    }

    /// Two INDEPENDENT subscriptions, deliberately not a `CombineLatest` of the two publishers: a
    /// tailer can append new items with no availability change (and vice versa), and
    /// `CombineLatest` would otherwise wait for both to have emitted at least once before ever
    /// firing, silently dropping the first update whichever publisher fires alone.
    func acquireMemberLease(_ id: String) {
        guard leases[id] == nil else { return }
        leases[id] = useCase.acquireEventLease(id)
        eventsByMember[id] = useCase.events(for: id)
        itemsByMember[id] = useCase.items(for: id)
        eventsAvailabilityByMember[id] = useCase.eventsAvailability(for: id)
        var subscriptions: [AnyCancellable] = []
        subscriptions.append(
            useCase.itemsPublisher(for: id)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] items in
                    guard let self else { return }
                    // The Timeline reads `items` directly (Monitor piece 8, Codex review round 2,
                    // finding 2) — never `Timeline.items(from:)` over the raw events below, which
                    // stays only for Summary/EditedFiles's own, separately-gated recompute.
                    itemsByMember[id] = items
                    eventsByMember[id] = useCase.events(for: id)
                    recompute()
                }
        )
        subscriptions.append(
            useCase.eventsAvailabilityPublisher(for: id)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] availability in
                    guard let self else { return }
                    eventsAvailabilityByMember[id] = availability
                    recompute()
                }
        )
        memberCancellables[id] = subscriptions
    }

    func releaseMemberLease(_ id: String) {
        leases[id]?.release()
        leases[id] = nil
        memberCancellables[id] = nil
        eventsByMember[id] = nil
        itemsByMember[id] = nil
        eventsAvailabilityByMember[id] = nil
    }
}
