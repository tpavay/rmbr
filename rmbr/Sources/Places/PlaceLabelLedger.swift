import Foundation

/// Every place label rmbr has ever resolved, kept forever.
///
/// This is durable memory, not a cache. A label is fetched once, on the day rmbr first
/// needed it, and is never resolved again: a business that closes or is renamed must
/// not silently rewrite what a day said (RE-036's historical-truth rule). Geoapify's
/// terms are what make keeping it lawful, and the attribution stored beside each label
/// is what keeps displaying it lawful.
///
/// Lookups are spatial, so one anchor visited on two hundred days costs one request.
struct PlaceLabelLedger: Sendable, Codable {
    /// Two coordinates this close are treated as the same physical anchor, matching the
    /// hard-merge distance used when clustering a day's fixes.
    static let matchDistanceMetres: Double = 25.0
    private static let cellDegrees = 0.001

    enum Outcome: Sendable, Codable, Hashable {
        case resolved(ResolvedPlaceLabel)
        /// The provider answered and supported no label at this coordinate. Recorded so
        /// rmbr does not ask again every time the day is opened.
        case unlabelled(attemptedAt: Date)
    }

    struct Entry: Sendable, Codable, Hashable {
        let coordinate: Coordinate
        let outcome: Outcome
    }

    private(set) var entries: [String: [Entry]] = [:]

    init() {}

    var count: Int { entries.values.reduce(0) { $0 + $1.count } }

    var resolvedCount: Int {
        entries.values.reduce(0) { total, list in
            total + list.filter { if case .resolved = $0.outcome { true } else { false } }.count
        }
    }

    func outcome(near coordinate: Coordinate) -> Outcome? {
        var best: (Double, Outcome)?
        for entry in candidates(near: coordinate) {
            let distance = entry.coordinate.distance(to: coordinate)
            guard distance <= Self.matchDistanceMetres else { continue }
            if best == nil || distance < best!.0 { best = (distance, entry.outcome) }
        }
        return best?.1
    }

    func label(near coordinate: Coordinate) -> ResolvedPlaceLabel? {
        if case .resolved(let label) = outcome(near: coordinate) { return label }
        return nil
    }

    /// Whether this coordinate still needs a provider request.
    func needsLookup(_ coordinate: Coordinate) -> Bool {
        outcome(near: coordinate) == nil
    }

    mutating func record(_ outcome: Outcome, at coordinate: Coordinate) {
        entries[Self.key(for: coordinate), default: []]
            .append(Entry(coordinate: coordinate, outcome: outcome))
    }

    private func candidates(near coordinate: Coordinate) -> [Entry] {
        let origin = Self.cell(for: coordinate)
        let metresPerLongitudeCell = max(
            0.5,
            Self.cellDegrees * 111_320 * cos(coordinate.latitude * .pi / 180)
        )
        let longitudeSpan = max(1, Int((Self.matchDistanceMetres / metresPerLongitudeCell).rounded(.up)))
        let latitudeSpan = max(1, Int((Self.matchDistanceMetres / (Self.cellDegrees * 110_574)).rounded(.up)))
        var result: [Entry] = []
        for latitudeOffset in -latitudeSpan...latitudeSpan {
            for longitudeOffset in -longitudeSpan...longitudeSpan {
                let key = "\(origin.0 + latitudeOffset):\(origin.1 + longitudeOffset)"
                if let bucket = entries[key] { result.append(contentsOf: bucket) }
            }
        }
        return result
    }

    private static func cell(for coordinate: Coordinate) -> (Int, Int) {
        (
            Int((coordinate.latitude / cellDegrees).rounded(.down)),
            Int((coordinate.longitude / cellDegrees).rounded(.down))
        )
    }

    private static func key(for coordinate: Coordinate) -> String {
        let cell = cell(for: coordinate)
        return "\(cell.0):\(cell.1)"
    }

    /// A synchronous lookup the composer can call while building a day.
    var lookup: DayComposer.PlaceLabelLookup {
        let snapshot = self
        return DayComposer.PlaceLabelLookup { coordinate in snapshot.label(near: coordinate) }
    }
}

/// Reads and writes the ledger.
///
/// Unlike the capture index, this is not excluded from backup: it is the one part of a
/// photographs-only day that cannot be rebuilt for free, because rebuilding it means
/// paying the provider again for labels rmbr is licensed to keep.
struct PlaceLabelLedgerStore: Sendable {
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        self.fileURL = base.appendingPathComponent("place-labels.json")
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support.appendingPathComponent("rmbr-memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func load() -> PlaceLabelLedger {
        guard let data = try? Data(contentsOf: fileURL),
              let ledger = try? JSONDecoder().decode(PlaceLabelLedger.self, from: data)
        else { return PlaceLabelLedger() }
        return ledger
    }

    func save(_ ledger: PlaceLabelLedger) throws {
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: fileURL, options: .atomic)
    }
}
