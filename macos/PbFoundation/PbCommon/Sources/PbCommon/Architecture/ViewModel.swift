//
//  ViewModel.swift
//  PbCommon
//
//  Only the `alert`/`dialog` publish helpers exist here (decision 10 drops toast, input dialog, image picker, paywall and
//  Sign in with Apple — the Monitor has none of those today).
//

@preconcurrency import Combine
import Foundation
import Mockable
import PbUtilities
import SwiftUI

// MARK: - DidPublishViewEventPublisher

/// Thread-safe publisher that broadcasts ``ViewEvent`` values from a
/// view model to the view layer via Combine.
public final class DidPublishViewEventPublisher: @unchecked Sendable {
    
    // MARK: - Properties
    
    let subject = PassthroughSubject<ViewEvent, Never>()
    
    /// A publisher that emits view events.
    public var publisher: AnyPublisher<ViewEvent, Never> {
        subject.eraseToAnyPublisher()
    }
    
    // MARK: - Methods
    
    /// Sends a view event to subscribers.
    /// - Parameter event: The view event to publish.
    public func send(_ event: ViewEvent) {
        subject.send(event)
    }
    
    /// Returns a publisher that receives events on the specified scheduler.
    /// - Parameter scheduler: The scheduler to receive events on.
    /// - Returns: An erased publisher.
    public func receive(on scheduler: DispatchQueue) -> AnyPublisher<ViewEvent, Never> {
        subject.receive(on: scheduler).eraseToAnyPublisher()
    }
}

// MARK: - ViewModel

/// Base protocol for all view models in the application.
///
/// Conforming types gain publish methods for ``ViewEvent`` values (alerts, dialogs) via the
/// extension below.
@Mockable
public protocol ViewModel: Observable, AnyObject {
    
    /// The publisher used to broadcast view events from this view model.
    var objectDidPublishViewEvent: DidPublishViewEventPublisher { get }
}

// MARK: - ViewModel Extension

@usableFromInline struct AssociatedKeys {
    @usableFromInline nonisolated(unsafe) static var objectDidPublishViewEvent: UInt8 = 0
}

extension ViewModel {
    
    /// The publisher used to broadcast view events from this view model.
    public var objectDidPublishViewEvent: DidPublishViewEventPublisher {
        if let subject = objc_getAssociatedObject(self, &AssociatedKeys.objectDidPublishViewEvent) as? DidPublishViewEventPublisher {
            return subject
        }
        let subject = DidPublishViewEventPublisher()
        objc_setAssociatedObject(self, &AssociatedKeys.objectDidPublishViewEvent, subject, .OBJC_ASSOCIATION_RETAIN)
        return subject
    }
    
    @inlinable public func publishViewEvent(_ event: ViewEvent) {
        let objectDidPublishViewEvent = objectDidPublishViewEvent
        Task { @MainActor in
            objectDidPublishViewEvent.send(event)
        }
    }
    
    // MARK: Alert
    
    @inlinable public func publishAlert(_ alert: AlertContent) {
        publishViewEvent(.alert(alert))
    }
    
    @inlinable public func publishAlert(_ title: String, description: String? = nil, @ArrayBuilder<AlertAction> actionsBuilder: () -> [AlertAction]) {
        publishAlert(AlertContent(title: title, description: description, actionsBuilder: actionsBuilder))
    }
    
    // MARK: Dialog
    
    @inlinable public func publishDialog(_ dialog: AlertContent) {
        publishViewEvent(.dialog(dialog))
    }
    
    @inlinable public func publishDialog(_ title: String, description: String? = nil, @ArrayBuilder<AlertAction> actionsBuilder: () -> [AlertAction]) {
        publishDialog(AlertContent(title: title, description: description, actionsBuilder: actionsBuilder))
    }
    
    // MARK: Others
    
    @inlinable public func flushViewEvent() {
        publishViewEvent(.none)
    }
}

// MARK: View + Extension

extension View {
    /// Bridges a view model's published ``ViewEvent`` stream into a `Binding` the presentation
    /// modifier (PbUI) reads to decide what to show.
    @inlinable public func publishViewEvent(from viewModel: any ViewModel, to binding: Binding<ViewEvent>) -> some View {
        onReceive(viewModel.objectDidPublishViewEvent.receive(on: DispatchQueue.main)) { output in
            binding.wrappedValue = output
        }
    }
}
