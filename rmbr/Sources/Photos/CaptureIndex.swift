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
    let metrics: IndexRunMetrics
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
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        self.fileURL = base.appendingPathComponent("capture-index.plist")
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support.appendingPathComponent("rmbr", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(excluded)
        return directory
    }

    func load() -> CaptureIndexSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let snapshot = try? PropertyListDecoder().decode(CaptureIndexSnapshot.self, from: data)
        else { return nil }
        guard snapshot.engineVersion == ReconstructionVersion.engine else { return nil }
        return snapshot
    }

    func save(_ snapshot: CaptureIndexSnapshot) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
