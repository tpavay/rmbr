import Foundation

/// A value that a source may or may not be able to establish.
///
/// `known(0)` and `unknown` are deliberately different states (RQ-005, RE-005).
/// A nullable scalar is never an acceptable substitute: it collapses "the source
/// returned a trustworthy zero" into "we cannot see", and the presentation layer
/// then prints one as the other.
///
/// Use an `Optional` only when the concept does not apply at all - a poster time
/// on a still photograph, for example. Use `unknown` when the concept applies but
/// no source could establish it.
enum EvidenceValue<Value: Sendable & Codable & Hashable>: Sendable, Codable, Hashable {
    case known(Value)
    case unknown(UnknownReason)

    var knownValue: Value? {
        if case .known(let value) = self { return value }
        return nil
    }

    var isKnown: Bool { knownValue != nil }

    func map<Other>(_ transform: (Value) -> Other) -> EvidenceValue<Other> {
        switch self {
        case .known(let value): .known(transform(value))
        case .unknown(let reason): .unknown(reason)
        }
    }
}

/// Why a value could not be established.
///
/// These are engine-facing reasons, not user-facing copy. Nothing in this list may
/// be rendered as a sentence about the person - in particular `noReadableSamplesOrReadDenied`
/// exists because HealthKit read refusal and an empty store are indistinguishable by
/// design, so neither "you did not sleep" nor "permission denied" is ever a truthful
/// rendering of it (RE-013, RQ-010).
enum UnknownReason: String, Sendable, Codable, Hashable {
    /// The source was never asked for, or is not part of this milestone's scope.
    case sourceNotCollected
    /// The source exists but the app is not authorised to read it.
    case sourceNotAuthorized
    /// The source is authorised but only over a subset of its data.
    case partialAuthorization
    /// The read returned nothing, and refusal cannot be distinguished from absence.
    case noReadableSamplesOrReadDenied
    /// The source has no record covering a period before the app was installed.
    case notCollectedBeforeInstall
    /// The source is unavailable on this device or in this build.
    case sourceUnavailable
    /// An observation exists but is incomplete (an arrival with no departure, say).
    case incompleteObservation
    /// Evidence exists but does not support the claim being asked for.
    case notEstablished
    /// A derivation ran and failed.
    case computationFailed
}
