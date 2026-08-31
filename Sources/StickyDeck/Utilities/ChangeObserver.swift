import Observation

/// Bridges Observation back to imperative AppKit code.
///
/// The deck's panel geometry, hit rects and first responder are owned by
/// `DeckController`, not by SwiftUI, so it has to react to view-model changes
/// from outside a `body`. `withObservationTracking` only fires once and reports
/// the change *before* it is applied, so an observer that wants the new value
/// must hop to the next main-actor turn and re-arm itself. This wraps that
/// loop, and matches what the Combine subscriptions it replaced did: delivery
/// is asynchronous on the main actor, and duplicate values can be suppressed.
///
/// Observation stops when the observer is released — holding it is the
/// subscription.
@MainActor
// `Value` must be Sendable: the re-arming closure `withObservationTracking`
// calls is @Sendable, so it captures the generic parameter's metatype.
final class ChangeObserver<Value: Equatable & Sendable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private let skipsDuplicates: Bool
    private var previous: Value

    /// - Parameters:
    ///   - skippingDuplicates: when true, `onChange` runs only if the value
    ///     actually differs, matching Combine's `removeDuplicates()`. Pass
    ///     false to react to every assignment, as a bare `sink` did.
    ///   - read: the value to watch. Every observable property it touches is
    ///     tracked.
    ///   - onChange: runs after the change has landed, with the new value.
    init(
        skippingDuplicates: Bool = true,
        reading read: @escaping @MainActor () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        self.read = read
        self.onChange = onChange
        self.skipsDuplicates = skippingDuplicates
        self.previous = read()
        arm()
    }

    private func arm() {
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            // Re-read on the next turn: inside `onChange` the mutation has not
            // been applied yet, so `read()` would still return the old value.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.read()
                let changed = current != self.previous
                self.previous = current
                self.arm()
                guard changed || !self.skipsDuplicates else { return }
                self.onChange(current)
            }
        }
    }
}

/// Type-erased handle so observers of different value types can be retained
/// together, the way `Set<AnyCancellable>` used to hold them.
@MainActor
protocol ChangeObservation: AnyObject {}

extension ChangeObserver: ChangeObservation {}
