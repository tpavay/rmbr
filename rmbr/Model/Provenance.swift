import Foundation

/// Which source a value came from.
///
/// Every source rmbr will ever read is listed, including the ones milestone 1
/// deliberately does not read, so coverage can state "not collected" about a named
/// source rather than staying silent about it.
enum SourceKind: String, Sendable, Codable, Hashable, CaseIterable {
    case photoLibrary
    case health
    case coreLocation
    case calendar
    case weather
    case userNote
    case userCorrection
    case placeProvider
}

/// How firmly a value is held.
///
/// Evidence, deterministic derivation, model inference, provider supply and person
/// correction stay distinct so a later correction can override presentation without
/// overwriting what the source actually said (RE-002).
enum ProvenanceClass: String, Sendable, Codable, Hashable {
    case directlyObserved
    case deterministicallyDerived
    case modelInferred
    case providerSupplied
    case personCorrected
}

/// Where a displayed value came from and by which rule.
///
/// Every non-trivial value carries one. A rule identifier plus version is what makes
/// a composition reproducible and a stale automatic result distinguishable from
/// person-authored intent (RE-007, RQ-004).
struct Provenance: Sendable, Codable, Hashable {
    let sourceKind: SourceKind
    let provenanceClass: ProvenanceClass
    /// Source records this value was computed from.
    let evidenceIDs: [EvidenceID]
    /// Name of the derivation rule, stable across releases.
    let ruleID: String
    /// Version of that rule, so output from an older rule is recognisable.
    let ruleVersion: String
    /// Present only for `.modelInferred` values.
    let confidence: Double?

    init(
        sourceKind: SourceKind,
        provenanceClass: ProvenanceClass,
        evidenceIDs: [EvidenceID] = [],
        ruleID: String,
        ruleVersion: String = ReconstructionVersion.engine,
        confidence: Double? = nil
    ) {
        self.sourceKind = sourceKind
        self.provenanceClass = provenanceClass
        self.evidenceIDs = evidenceIDs
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.confidence = confidence
    }
}

/// Versions that participate in every cache key and source fingerprint.
enum ReconstructionVersion {
    /// Bumped whenever composition output can change for unchanged sources.
    static let engine = "m1.0"
    /// Bumped whenever the persisted `Day` shape changes.
    static let schema = 1
}
