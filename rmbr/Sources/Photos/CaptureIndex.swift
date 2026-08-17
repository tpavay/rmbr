import Foundation

/// Every accessible capture, bucketed by the civil day it belongs to.
///
/// The whole index stays resident. At the captain's measured library size - 23,743
/// assets over 6,666 days - the records cost a few megabytes, and holding them means
/// composing a day is arithmetic over a handful of values rather than a PhotoKit query.
/// That is what makes a decade of scroll possible: the expensive work is the one-time
/// walk that built this, not the day the person just landed on.
struct CaptureIndex: Sendable, Codable {
    let timeZoneID: String
    /// Days with at least one accessible capture, oldest first.
    let datesWithCaptures: [LocalDate]
    private let recordsByDate: [String: [CaptureRecord]]

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    init(records: [CaptureRecord], timeZone: TimeZone) {
        self.timeZoneID = timeZone.identifier
        var buckets: [String: [CaptureRecord]] = [:]
        for record in records {
            let date = LocalDate(
                components: record.captureTime.localComponents(defaultTimeZone: timeZone)
            ) ?? LocalDate(instant: record.instant, in: timeZone)
            buckets[date.description, default: []].append(record)
        }
        for key in buckets.keys {
            buckets[key]?.sort(by: MomentBuilder.captureOrder)
        }
        self.recordsByDate = buckets
        self.datesWithCaptures = buckets.keys
            .compactMap(Self.parse)
            .sorted()
    }

    func records(on date: LocalDate) -> [CaptureRecord] {
        recordsByDate[date.description] ?? []
    }

    var isEmpty: Bool { recordsByDate.isEmpty }

    var totalRecordCount: Int { recordsByDate.values.reduce(0) { $0 + $1.count } }

    var earliestDate: LocalDate? { datesWithCaptures.first }
    var latestDate: LocalDate? { datesWithCaptures.last }

    func dates(in month: Month) -> [LocalDate] {
        datesWithCaptures.filter { month.contains($0) }
    }

    /// Months, newest first, that contain at least one capture.
    func monthsWithCaptures() -> [Month] {
        var seen: Set<Month> = []
        var ordered: [Month] = []
        for date in datesWithCaptures.reversed() {
            let month = Month(year: date.year, month: date.month)
            if seen.insert(month).inserted { ordered.append(month) }
        }
        return ordered
    }

    private static func parse(_ key: String) -> LocalDate? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }
}

/// A persisted index, plus what it would take to know it is stale.
struct CaptureIndexSnapshot: Sendable, Codable {
    let builtAt: Date
    let engineVersion: String
    let index: CaptureIndex
    var metrics: IndexRunMetrics
    /// Access level in force when the walk ran. A snapshot built under limited access
    /// must not later be presented as exhaustive.
    let wasFullAccess: Bool
    /// What the library looked like when the walk ran, so a later launch can tell
    /// whether this snapshot still describes it.
    let signature: LibrarySignature
}

/// Reads and writes the index snapshot.
///
/// The snapshot is a cache: everything in it is reproducible from PhotoKit, so it lives
/// outside iCloud backup and can be deleted at any time without losing anything the
/// person authored.
struct CaptureIndexStore: Sendable {
    /// Nil when no directory could be confirmed excluded from backup, in which case the
    /// snapshot is not written: it describes the whole library, and a warm launch is not
    /// worth a copy of that record leaving the device.
    let fileURL: URL?
    /// What writing the snapshot cost, kept beside the snapshot rather than inside it: a
    /// figure measured by writing a file cannot also be part of the file it measures.
    let metricsURL: URL?

    init(directory: URL? = nil) {
        let base = directory.flatMap(PrivateStorage.excluding)
            ?? (directory == nil ? PrivateStorage.excludedDirectory(named: "rmbr") : nil)
        self.fileURL = base?.appendingPathComponent("capture-index.plist")
        self.metricsURL = base?.appendingPathComponent("capture-index-metrics.plist")
    }

    func load() -> CaptureIndexSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        guard var snapshot = try? PropertyListDecoder().decode(CaptureIndexSnapshot.self, from: data)
        else { return nil }
        guard snapshot.engineVersion == ReconstructionVersion.engine else { return nil }
        // The measured cost of the write is only adopted for the snapshot it describes.
        if let record = loadMetrics(), record.builtAt == snapshot.builtAt {
            snapshot.metrics = record.metrics
        }
        return snapshot
    }

    /// Writes the snapshot and answers what writing it cost.
    ///
    /// The returned figure is the persist time a run reports, and the same figure is
    /// recorded beside the snapshot so a later warm launch describes the run that built
    /// the index with the time it actually took.
    @discardableResult
    func save(_ snapshot: CaptureIndexSnapshot) throws -> Double {
        guard let fileURL else { throw PrivateStorageFailure.notExcludedFromBackup }
        let started = Date()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        let elapsed = Date().timeIntervalSince(started)

        var measured = snapshot.metrics
        measured.persistSeconds = elapsed
        let record = CaptureIndexMetricsRecord(builtAt: snapshot.builtAt, metrics: measured)
        if let metricsURL, let recordData = try? encoder.encode(record) {
            try? recordData.write(to: metricsURL, options: .atomic)
        }
        return elapsed
    }

    func clear() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        if let metricsURL { try? FileManager.default.removeItem(at: metricsURL) }
    }

    private func loadMetrics() -> CaptureIndexMetricsRecord? {
        guard let metricsURL, let data = try? Data(contentsOf: metricsURL) else { return nil }
        return try? PropertyListDecoder().decode(CaptureIndexMetricsRecord.self, from: data)
    }
}

/// The completed cost of one index build, written after the snapshot it belongs to.
struct CaptureIndexMetricsRecord: Sendable, Codable {
    let builtAt: Date
    let metrics: IndexRunMetrics
}
