import Foundation
import Observation
import Photos

enum LibraryPhase: Sendable, Hashable {
    case checkingPermission
    case awaitingPermission
    case permissionRefused(PhotoLibraryAccess)
    case indexing(done: Int, total: Int)
    case ready
    case failed(String)
}

/// Holds composed days without notifying observers.
///
/// Composition happens while a view is being laid out, so it must not invalidate the
/// observation that triggered it. Keeping the cache outside the observed model is what
/// stops that loop.
final class DayCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Day] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 600) { self.limit = limit }

    func day(_ date: LocalDate) -> Day? {
        lock.lock(); defer { lock.unlock() }
        return storage[date.description]
    }

    func store(_ day: Day) {
        lock.lock(); defer { lock.unlock() }
        let key = day.date.description
        if storage[key] == nil { order.append(key) }
        storage[key] = day
        while order.count > limit {
            let evicted = order.removeFirst()
            storage[evicted] = nil
        }
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }
}

/// Everything the interface reads, and the only thing that talks to the sources.
@MainActor
@Observable
final class LibraryModel {
    private(set) var phase: LibraryPhase = .checkingPermission
    private(set) var access: PhotoLibraryAccess = .notDetermined
    private(set) var lifeEntries: [LifeEntry] = []
    private(set) var metrics: IndexRunMetrics?
    private(set) var surveySeconds: Double = 0
    private(set) var indexBuiltAt: Date?
    private(set) var loadedFromCache = false
    private(set) var monthEntries: [MonthEntry] = []
    private(set) var placeReport = PlaceResolutionReport()
    private(set) var hasPlaceCredential = false
    private(set) var ledgerLabelCount = 0

    let tuning = ReconstructionTuningProfile.v1
    private let composer: DayComposer
    private let indexStore = CaptureIndexStore()
    private let resolver = PlaceNameResolver()
    private let credentials = GeoapifyCredentialStore()
    private let cache = DayCache()

    private var index: CaptureIndex?
    private var ledger = PlaceLabelLedger()
    private var representativeDates: Set<LocalDate> = []
    private var placeRequestsInFlight: Set<String> = []

    init() {
        self.composer = DayComposer(tuning: .v1, boundaryPolicy: MidnightDayBoundaryPolicy())
    }

    var today: LocalDate { LocalDate(instant: Date(), in: index?.timeZone ?? .current) }

    var indexedRecordCount: Int { index?.totalRecordCount ?? 0 }
    var earliestIndexedDate: LocalDate? { index?.earliestDate }

    // MARK: - Lifecycle

    func start() async {
        access = PhotoLibraryAuthorization.current
        hasPlaceCredential = credentials.hasKey
        ledger = await resolver.currentLedger
        ledgerLabelCount = ledger.resolvedCount

        switch access {
        case .notDetermined:
            phase = .awaitingPermission
        case .denied, .restricted:
            phase = .permissionRefused(access)
        case .full, .limited:
            await loadOrBuildIndex()
        }
    }

    func requestAccess() async {
        access = await PhotoLibraryAuthorization.request()
        switch access {
        case .full, .limited: await loadOrBuildIndex()
        case .denied, .restricted, .notDetermined: phase = .permissionRefused(access)
        }
    }

    /// Loads the cached index if one survives, and otherwise walks the library.
    ///
    /// A cached snapshot means a warm launch costs a file read. The walk is the cost
    /// that gets reported: it is the first-run number.
    func loadOrBuildIndex(forceRebuild: Bool = false) async {
        if !forceRebuild {
            // A warm launch costs one file read plus two bounded PhotoKit fetches, and
            // none of it happens on the main actor: a cached launch must not block the
            // first frame for as long as the library is large. The full walk runs again
            // only when the library has actually moved.
            let store = indexStore
            let wantsExhaustive = access.isExhaustive
            let warm = await Task.detached(priority: .userInitiated) {
                () -> (CaptureIndexSnapshot, LibrarySignature)? in
                guard let snapshot = store.load(),
                      snapshot.wasFullAccess == wantsExhaustive else { return nil }
                return (snapshot, PhotoLibraryIndexer.librarySignature())
            }.value

            if let (snapshot, signature) = warm, signature == snapshot.signature {
                index = snapshot.index
                metrics = snapshot.metrics
                indexBuiltAt = snapshot.builtAt
                loadedFromCache = true
                await finishIndexing()
                return
            }
        }

        loadedFromCache = false
        phase = .indexing(done: 0, total: 0)

        let timeZone = TimeZone.current
        let indexer = PhotoLibraryIndexer(timeZone: timeZone)
        let progress: PhotoLibraryIndexer.ProgressHandler = { [weak self] done, total in
            Task { @MainActor [weak self] in
                self?.phase = .indexing(done: done, total: total)
            }
        }

        do {
            let (output, signature) = try await Task.detached(priority: .userInitiated) {
                (try indexer.buildIndex(progress: progress), PhotoLibraryIndexer.librarySignature())
            }.value
            let built = CaptureIndex(records: output.records, timeZone: timeZone)
            index = built
            metrics = output.metrics
            indexBuiltAt = Date()
            cache.invalidateAll()

            let snapshot = CaptureIndexSnapshot(
                builtAt: Date(),
                engineVersion: ReconstructionVersion.engine,
                index: built,
                metrics: output.metrics,
                wasFullAccess: access.isExhaustive,
                signature: signature
            )
            let store = indexStore
            let persistSeconds = await Task.detached(priority: .userInitiated) {
                (try? store.save(snapshot)) ?? 0
            }.value
            // The reported total is what the run cost, persistence included, both here
            // and in the snapshot a later warm launch reads back.
            var measured = output.metrics
            measured.persistSeconds = persistSeconds
            metrics = measured

            await finishIndexing()
        } catch is CancellationError {
            phase = .failed("Indexing was cancelled.")
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func finishIndexing() async {
        guard let index else {
            phase = .failed("No index.")
            return
        }
        let tuning = tuning
        let today = today
        let survey = await Task.detached(priority: .userInitiated) {
            ArchiveSurveyor.survey(index: index, tuning: tuning)
        }.value
        surveySeconds = survey.elapsedSeconds
        monthEntries = ArchiveSurveyor.monthEntries(
            index: index,
            survey: survey,
            today: today,
            tuning: tuning
        )
        representativeDates = Set(
            monthEntries.compactMap {
                if case .representative(let value) = $0 { value.date } else { nil }
            }
        )
        lifeEntries = LifeEntryBuilder.build(
            index: index,
            monthEntries: monthEntries,
            today: today,
            tuning: tuning
        )
        phase = .ready
        printReconstructionReport()
    }

    /// Prints what the run cost, so a device run produces a number without a screenshot.
    ///
    /// Acceptance for this milestone includes reporting how long a first run on a large
    /// library actually took. A console line makes that a measurement rather than an
    /// impression, and it is the same figure the diagnostics screen shows.
    private func printReconstructionReport() {
        guard let metrics else { return }
        var lines: [String] = []
        lines.append("== rmbr reconstruction ==")
        lines.append("source            : \(loadedFromCache ? "cached snapshot" : "fresh library walk")")
        lines.append("access            : \(access)")
        lines.append("assets walked     : \(metrics.assetCount)")
        lines.append("records indexed   : \(metrics.recordCount)")
        lines.append("no creation date  : \(metrics.skippedWithoutCreationDate)")
        lines.append("geotagged         : \(metrics.geotaggedCount)")
        lines.append("screenshots       : \(metrics.screenshotCount)")
        lines.append(String(format: "fetch             : %.3f s", metrics.fetchSeconds))
        lines.append(String(format: "property walk     : %.3f s", metrics.walkSeconds))
        lines.append(String(format: "persist           : %.3f s", metrics.persistSeconds))
        lines.append(String(format: "index total       : %.3f s", metrics.totalSeconds))
        lines.append(String(format: "rate              : %.0f assets/s", metrics.assetsPerSecond))
        lines.append(String(format: "archive survey    : %.3f s", surveySeconds))
        lines.append("days with captures: \(index?.datesWithCaptures.count ?? 0)")
        lines.append("earliest day      : \(index?.earliestDate?.description ?? "-")")
        lines.append("life rows         : \(lifeEntries.count)")
        lines.append("older months      : \(monthEntries.count)")
        let empty = monthEntries.filter { if case .noRepresentative = $0 { true } else { false } }.count
        lines.append("months with nothing: \(empty)")
        print(lines.joined(separator: "\n"))
    }

    // MARK: - Days

    /// Composes a day, or returns the cached composition.
    ///
    /// Pure and synchronous: safe to call while laying out a row. Place names are not
    /// fetched here - a day is readable before it is named.
    func day(for date: LocalDate) -> Day {
        if let cached = cache.day(date) { return cached }
        let records = index?.records(on: date) ?? []
        let result = composer.compose(
            date: date,
            captures: records,
            context: DayComposer.Context(
                timeZone: index?.timeZone ?? .current,
                hasFullLibraryAccess: access.isExhaustive,
                placeLabels: ledger.lookup,
                composedAt: Date()
            )
        )
        cache.store(result.day)
        return result.day
    }

    func treatment(for date: LocalDate) -> BackfillTreatment {
        BackfillPolicy(tuning: tuning).treatment(
            for: date,
            today: today,
            representatives: representativeDates
        )
    }

    /// Fetches any place labels this day wants and recomposes it once they land.
    func resolvePlaceNames(for date: LocalDate) async {
        guard let index else { return }
        let records = index.records(on: date)
        let result = composer.compose(
            date: date,
            captures: records,
            context: DayComposer.Context(
                timeZone: index.timeZone,
                hasFullLibraryAccess: access.isExhaustive,
                placeLabels: ledger.lookup,
                composedAt: Date()
            )
        )
        guard !result.pendingPlaceLookups.isEmpty else { return }
        let key = date.description
        guard !placeRequestsInFlight.contains(key) else { return }
        placeRequestsInFlight.insert(key)
        defer { placeRequestsInFlight.remove(key) }

        let (updated, report) = await resolver.resolve(result.pendingPlaceLookups)
        ledger = updated
        ledgerLabelCount = updated.resolvedCount
        placeReport = report
        cache.invalidateAll()
    }

    // MARK: - Places credential

    func storePlaceCredential(_ key: String) {
        credentials.write(key)
        hasPlaceCredential = credentials.hasKey
    }

    func removePlaceCredential() {
        credentials.delete()
        hasPlaceCredential = credentials.hasKey
    }

    // MARK: - Life

    /// Every date with captures in a month, for the month destination.
    ///
    /// Opening a month composes its days on demand; it never injects them into Life
    /// (RQ-069).
    func dates(in month: Month) -> [LocalDate] {
        (index?.dates(in: month) ?? []).sorted(by: >)
    }

    func representative(for month: Month) -> MonthlyRepresentative? {
        for entry in monthEntries {
            if case .representative(let value) = entry, value.month == month { return value }
        }
        return nil
    }
}
