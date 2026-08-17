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
    private var limit: Int

    init(limit: Int = 600) { self.limit = limit }

    /// Grows the cache to hold a whole composed window.
    ///
    /// The backfill schedule composes the recent window up front, and a cache smaller
    /// than that window would evict the earliest of those days while the later ones were
    /// still being composed - paying for the work and then throwing it away.
    func reserve(atLeast count: Int) {
        lock.lock(); defer { lock.unlock() }
        limit = max(limit, count)
    }

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
    /// Days the backfill schedule composed up front, and what composing them cost.
    private(set) var composedDayCount = 0
    private(set) var composeSeconds: Double = 0
    /// Attribution lines owed by the labels the composed days carry, taken from the days
    /// themselves so a screen that shows a stored label cannot show it uncredited.
    private(set) var placeAttributions: [String] = []

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
    private var signalsByDate: [LocalDate: DaySignals] = [:]
    private var hasStarted = false
    private var isLoading = false
    /// What the library looked like when the rows on screen were built, and which day it
    /// was when they were built. Either changing is what makes the work worth redoing.
    private var currentSignature: LibrarySignature?
    private var builtForDay: LocalDate?

    init() {
        self.composer = DayComposer(tuning: .v1, boundaryPolicy: MidnightDayBoundaryPolicy())
    }

    /// Which day it is now, in the zone the phone is in now.
    ///
    /// The floating-local rule protects which day a *photograph* belongs to against a
    /// zone change. Today is a statement about the present, so it follows the phone: a
    /// person who has flown somewhere must not see yesterday's row headed "Today".
    var today: LocalDate { LocalDate(instant: Date(), in: .current) }

    var indexedRecordCount: Int { index?.totalRecordCount ?? 0 }
    var earliestIndexedDate: LocalDate? { index?.earliestDate }

    // MARK: - Lifecycle

    func start() async {
        hasStarted = true
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

    /// Rechecks what rmbr is allowed to see, and whether the library has moved.
    ///
    /// Photo access is changed in Settings, not in rmbr, so the answer can be different
    /// every time the app comes back to the foreground - including from full to a chosen
    /// subset, which invalidates every count the index holds. The warm path costs a file
    /// read and two bounded fetches, both off the main actor, so asking each time is
    /// cheaper than being wrong until the next launch.
    func refresh() async {
        guard hasStarted, !isLoading else { return }
        let current = PhotoLibraryAuthorization.current
        hasPlaceCredential = credentials.hasKey
        let changed = current != access
        access = current

        switch current {
        case .notDetermined:
            if changed { forgetLibrary() }
            phase = .awaitingPermission
        case .denied, .restricted:
            if changed { forgetLibrary() }
            phase = .permissionRefused(current)
        case .full, .limited:
            await loadOrBuildIndex()
        }
    }

    /// Drops everything built from a library rmbr may no longer read.
    private func forgetLibrary() {
        index = nil
        lifeEntries = []
        monthEntries = []
        signalsByDate = [:]
        representativeDates = []
        placeAttributions = []
        composedDayCount = 0
        composeSeconds = 0
        cache.invalidateAll()
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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

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
                // Coming back to the foreground with the same library, on the same day,
                // has nothing to redo: the survey and the composed window still describe
                // what is on screen.
                if index != nil, currentSignature == signature, builtForDay == today,
                   phase == .ready {
                    return
                }
                index = snapshot.index
                metrics = snapshot.metrics
                indexBuiltAt = snapshot.builtAt
                loadedFromCache = true
                currentSignature = signature
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
            currentSignature = signature
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
        signalsByDate = survey.signalsByDate
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
        await composeBackfill(index: index)
        builtForDay = today
        phase = .ready
        printReconstructionReport()
    }

    /// Composes everything the backfill schedule entitles to composition, up front.
    ///
    /// The recent window's days and each older month's representative are exactly the
    /// rows Life shows, and they are composed and cached here rather than while a row is
    /// being laid out. Every other day stays indexed-only until it is opened (RQ-064).
    /// The work runs off the main actor, as the survey before it does.
    private func composeBackfill(index: CaptureIndex) async {
        let dates = lifeEntries.compactMap { entry -> LocalDate? in
            if case .day(let date, _) = entry { return date }
            return nil
        }
        guard !dates.isEmpty else {
            composedDayCount = 0
            composeSeconds = 0
            placeAttributions = []
            return
        }

        cache.reserve(atLeast: dates.count + 64)
        let composer = composer
        let cache = cache
        let placeLabels = ledger.lookup
        let hasFullAccess = access.isExhaustive
        let timeZone = index.timeZone

        let outcome = await Task.detached(priority: .userInitiated) { () -> (Double, [String]) in
            let started = Date()
            var attributions: [String] = []
            for date in dates {
                let result = composer.compose(
                    date: date,
                    captures: index.records(on: date),
                    context: DayComposer.Context(
                        timeZone: timeZone,
                        hasFullLibraryAccess: hasFullAccess,
                        placeLabels: placeLabels,
                        composedAt: Date()
                    )
                )
                cache.store(result.day)
                for line in result.day.placeAttributions where !attributions.contains(line) {
                    attributions.append(line)
                }
            }
            return (Date().timeIntervalSince(started), attributions)
        }.value

        composedDayCount = dates.count
        composeSeconds = outcome.0
        placeAttributions = outcome.1
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
        lines.append(String(format: "backfill compose  : %.3f s", composeSeconds))
        lines.append("days composed     : \(composedDayCount)")
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

    /// A row's line for a day that has not been composed.
    ///
    /// Opening a month must not compose every day in it. The archive survey already
    /// knows how much each day holds and where its anchors are, and the ledger already
    /// knows what those anchors are called, so a month row is honest without doing a day
    /// page's work (RQ-069).
    func summary(for date: LocalDate) -> DayRowSummary {
        let signals = signalsByDate[date]
        let label = signals?.placeAnchorCentroids.compactMap { ledger.label(near: $0) }.first
        return DayRowSummary(
            placeName: label?.text,
            attribution: label?.attribution,
            visibleMediaCount: signals?.eligibleMediaCount ?? 0,
            placeCount: signals?.distinctPlaceCount ?? 0,
            hasExhaustiveCounts: access.isExhaustive
        )
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
        // Every composed day may now carry a label it did not have, so the composed
        // window is rebuilt rather than left to recompose a row at a time while it is
        // being laid out.
        cache.invalidateAll()
        await composeBackfill(index: index)
        for line in day(for: date).placeAttributions where !placeAttributions.contains(line) {
            placeAttributions.append(line)
        }
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
