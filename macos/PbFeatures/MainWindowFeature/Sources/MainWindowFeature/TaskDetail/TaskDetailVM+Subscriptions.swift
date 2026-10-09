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
        let epoch = timelineEpoch

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
                recomputeMembersAndLeases()
            }
            .store(in: &cancellables)

        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
                hasListed = value
                recompute()
            }
            .store(in: &cancellables)

        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
                recompute()
            }
            .store(in: &cancellables)

        useCase.snapshotsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
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
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
                latestBusy = busy
                recompute()
            }
            .store(in: &cancellables)

        useCase.outcomesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomes in
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
                latestOutcomes = outcomes
                recompute()
            }
            .store(in: &cancellables)
    }

    func acquireSummaryMembers(_ ids: [String]) {
        memberLeaseAcquisition?.cancel()
        let missing = ids.filter { summaryLeases[$0] == nil }
        guard !missing.isEmpty else { return }
        let epoch = timelineEpoch
        memberLeaseAcquisition = Task { [weak self] in
            var count = 0
            var batchStart = ContinuousClock.now
            for id in missing {
                guard let self, !Task.isCancelled, timelineEpoch == epoch,
                      conversationMembers.contains(where: { $0.taskID == id }) else { return }
                if summaryLeases[id] == nil {
                    summaryLeases[id] = useCase.acquireSummaryLease(id)
                    summaryCancellables[id] = useCase.eventSummaryPublisher(for: id)
                        .receive(on: DispatchQueue.main)
.sink { [weak self] _ in
                            guard let self, timelineEpoch == epoch, summaryLeases[id] != nil else { return }
                            recompute()
                        }
                }
                count += 1
                if count >= 4 || batchStart.duration(to: .now) >= .milliseconds(4) {
                    await Task.yield()
                    count = 0
                    batchStart = .now
                }
            }
        }
    }

    /// Two INDEPENDENT subscriptions, deliberately not a `CombineLatest` of the two publishers: a
    /// tailer can append new items with no availability change (and vice versa), and
    /// `CombineLatest` would otherwise wait for both to have emitted at least once before ever
    /// firing, silently dropping the first update whichever publisher fires alone.
    func acquireMemberLease(_ id: String) {
        guard leases[id] == nil else { return }
        let epoch = timelineEpoch
        let token = UUID()
        memberLeaseTokens[id] = token
        leases[id] = useCase.acquireEventLease(id)
        eventsByMember[id] = useCase.events(for: id)
        itemsByMember[id] = useCase.items(for: id)
        eventsAvailabilityByMember[id] = useCase.eventsAvailability(for: id)
        var subscriptions: [AnyCancellable] = []
        subscriptions.append(
            useCase.itemsPublisher(for: id)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] items in
                    guard let self, timelineEpoch == epoch, memberLeaseTokens[id] == token else { return }
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
                    guard let self, timelineEpoch == epoch, memberLeaseTokens[id] == token else { return }
                    eventsAvailabilityByMember[id] = availability
                    recompute()
                }
        )
        subscriptions.append(useCase.eventHistoryPublisher(for: id).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, timelineEpoch == epoch, memberLeaseTokens[id] == token else { return }
            recompute()
        })
        subscriptions.append(useCase.eventSummaryPublisher(for: id).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, timelineEpoch == epoch, memberLeaseTokens[id] == token else { return }
            recompute()
        })
        memberCancellables[id] = subscriptions
    }

    func releaseMemberLease(_ id: String) {
        leases[id]?.release()
        leases[id] = nil
        memberLeaseTokens[id] = nil
        memberCancellables[id] = nil
        eventsByMember[id] = nil
        itemsByMember[id] = nil
        eventsAvailabilityByMember[id] = nil
    }
}
