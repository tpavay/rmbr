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
/// The days the backfill schedule composed are kept apart from the days a person happened
/// to open. Only the opened ones are subject to eviction, so a long browse can never cost
/// the scheduled window its composition and leave Life rebuilding a row mid-layout.
final class DayCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Day] = [:]
    private var scheduled: Set<String> = []
    private var opened: [String] = []
    private let openedLimit: Int

    init(openedLimit: Int = 256) { self.openedLimit = openedLimit }

    func day(_ date: LocalDate) -> Day? {
        lock.lock(); defer { lock.unlock() }
        return storage[date.description]
    }

    func store(_ day: Day, scheduled isScheduled: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let key = day.date.description
        storage[key] = day
        if isScheduled {
            scheduled.insert(key)
            if let index = opened.firstIndex(of: key) { opened.remove(at: index) }
            return
        }
        guard !scheduled.contains(key) else { return }
        if !opened.contains(key) { opened.append(key) }
        evictOverflow()
    }

    /// Releases the previously scheduled days, which become ordinary entries and the
    /// first in line to be evicted once a new schedule has been composed.
    func clearSchedule() {
        lock.lock(); defer { lock.unlock() }
        opened.insert(contentsOf: scheduled.sorted().filter { !opened.contains($0) }, at: 0)
        scheduled.removeAll()
        evictOverflow()
    }

    /// Drops one day, so the next read composes it against whatever is known now.
    func invalidate(_ date: LocalDate) {
        lock.lock(); defer { lock.unlock() }
        let key = date.description
        storage[key] = nil
        scheduled.remove(key)
        if let index = opened.firstIndex(of: key) { opened.remove(at: index) }
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        scheduled.removeAll()
        opened.removeAll()
    }

    private func evictOverflow() {
        while opened.count > openedLimit {
            let evicted = opened.removeFirst()
            storage[evicted] = nil
        }
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
    /// Bumped whenever the index is replaced or dropped. Anything derived from PhotoKit
    /// outside this model - decoded thumbnails above all - belongs to one generation and
    /// must be released when it ends, because the next one may be allowed to see less.
    private(set) var libraryGeneration = 0

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
    /// A foreground authorisation check that arrived while a load was running. It is the
    /// only check there is, so it is queued rather than dropped: the running load may be
    /// building against a grant that has since been narrowed.
    private var refreshPending = false
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
        guard hasStarted else { return }
        guard !isLoading else {
            refreshPending = true
            return
        }
        let current = PhotoLibraryAuthorization.current
        hasPlaceCredential = credentials.hasKey
        let changed = current != access
        access = current
        // A label that only reached memory last time is still owed to the ledger.
        if await resolver.persistPendingLabels() { placeReport.labelsPersisted = true }

        switch current {
        case .notDetermined:
            if changed { forgetLibrary() }
            phase = .awaitingPermission
        case .denied, .restricted:
            if changed { forgetLibrary() }
            phase = .permissionRefused(current)
        case .full, .limited:
            // Full to limited narrows what may be shown, and limited to full changes what
            // every count means. Neither may keep serving the old index and the pixels
            // decoded from it while the replacement is being built.
            if changed { forgetLibrary() }
            await loadOrBuildIndex()
        }
    }

    /// Drops everything built from a library rmbr may no longer read.
    private func forgetLibrary() {
        index = nil
        currentSignature = nil
        builtForDay = nil
        lifeEntries = []
        monthEntries = []
        signalsByDate = [:]
        representativeDates = []
        placeAttributions = []
        composedDayCount = 0
        composeSeconds = 0
        cache.invalidateAll()
        libraryGeneration += 1
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
        // Indexing a library rmbr may not read would walk nothing and then report itself
        // ready, which is a claim about an empty library rather than about a refusal.
        guard access.canRead else { return }
        guard !isLoading else {
            refreshPending = true
            return
        }
        isLoading = true
        await performLoad(forceRebuild: forceRebuild)
        isLoading = false

        // An authorisation check that arrived mid-load, or a grant that moved under one,
        // is answered now rather than waiting for the next time the app is reopened.
        if refreshPending {
            refreshPending = false
            await refresh()
        }
    }

    private func performLoad(forceRebuild: Bool) async {
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
                // Under a limited grant the signature also fingerprints which assets the
                // grant covers, so swapping one chosen photograph for another is seen.
                return (snapshot, PhotoLibraryIndexer.librarySignature(
                    coversWholeLibrary: wantsExhaustive
                ))
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
                cache.invalidateAll()
                libraryGeneration += 1
                await finishIndexing()
                return
            }
        }

        // Reaching here means no cached snapshot describes what rmbr may currently see -
        // the grant narrowed, the selection changed, or the library moved. Whatever was
        // built from the old one stops being served now, not when the rebuild lands.
        if index != nil { forgetLibrary() }

        loadedFromCache = false
        phase = .indexing(done: 0, total: 0)

        let timeZone = TimeZone.current
        let indexer = PhotoLibraryIndexer(timeZone: timeZone)
        let progress: PhotoLibraryIndexer.ProgressHandler = { [weak self] done, total in
            Task { @MainActor [weak self] in
                self?.phase = .indexing(done: done, total: total)
            }
        }

        let wantsExhaustive = access.isExhaustive
        do {
            // The walk and the signature are separate PhotoKit reads, so the selection
            // could move between them and leave records described by a fingerprint they
            // do not belong to. Bracketing the walk is what makes the pair consistent.
            let walked = try await Task.detached(priority: .userInitiated) {
                () -> (PhotoLibraryIndexer.Output, LibrarySignature)? in
                let before = PhotoLibraryIndexer.librarySignature(
                    coversWholeLibrary: wantsExhaustive
                )
                let output = try indexer.buildIndex(progress: progress)
                let after = PhotoLibraryIndexer.librarySignature(
                    coversWholeLibrary: wantsExhaustive
                )
                guard before == after else { return nil }
                return (output, after)
            }.value

            guard let (output, signature) = walked else {
                // The library changed under the walk. Nothing from it is published, and
                // the queued pass indexes what the grant covers now.
                refreshPending = true
                return
            }
            let built = CaptureIndex(records: output.records, timeZone: timeZone)
            index = built
            metrics = output.metrics
            indexBuiltAt = Date()
            currentSignature = signature
            cache.invalidateAll()
            libraryGeneration += 1

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

        // Nothing built against a grant that has since changed may be published, and the
        // authorisation enum alone cannot see that: one limited selection swapped for
        // another is still `.limited`. The signature is read once more, and a check that
        // arrived while this ran is reason enough to hold back on its own.
        let wantsExhaustive = access.isExhaustive
        let latestSignature = await Task.detached(priority: .userInitiated) {
            PhotoLibraryIndexer.librarySignature(coversWholeLibrary: wantsExhaustive)
        }.value
        guard !refreshPending,
              PhotoLibraryAuthorization.current == access,
              latestSignature == currentSignature else {
            // The queued refresh rebuilds against whatever rmbr is allowed to see now.
            refreshPending = true
            return
        }
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

        let composer = composer
        let placeLabels = ledger.lookup
        let hasFullAccess = access.isExhaustive
        let timeZone = index.timeZone
        let generation = libraryGeneration

        // Composed away from the shared cache, so a pass overtaken by a rebuild cannot
        // put records the new grant may not cover in front of anybody. A detached task
        // does not inherit the caller's cancellation, so it is forwarded explicitly and
        // answered inside the loop: nobody is waiting for a window nobody is looking at.
        let work = Task.detached(priority: .userInitiated) { () -> ([Day], Double, [String])? in
            let started = Date()
            var days: [Day] = []
            var attributions: [String] = []
            var credits: Set<String> = []
            for date in dates {
                if Task.isCancelled { return nil }
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
                days.append(result.day)
                for line in result.day.placeAttributions
                where credits.insert(ResolvedPlaceLabel.creditKey(line)).inserted {
                    attributions.append(line)
                }
            }
            return (days, Date().timeIntervalSince(started), attributions)
        }
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }

        // Cancelled, or the library moved while this pass ran - in which case what it
        // composed describes records rmbr may no longer be allowed to show. Either way it
        // is dropped without ever being stored.
        guard let outcome, !Task.isCancelled, libraryGeneration == generation else { return }

        cache.clearSchedule()
        for day in outcome.0 { cache.store(day, scheduled: true) }
        composedDayCount = dates.count
        composeSeconds = outcome.1
        placeAttributions = outcome.2
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
        // The same anchor the composed day would print first, so a month row and the day
        // it opens can never name two different places.
        let lookup = ledger
        let label = signals?.chronologicalAnchorCentroids
            .lazy
            .compactMap { lookup.label(near: $0) }
            .first
        return DayRowSummary(
            placeName: label?.text,
            attributions: label?.attributions ?? [],
            counts: signals?.rawCounts ?? RawCaptureCounts(),
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

        let generation = libraryGeneration
        let (updated, report) = await resolver.resolve(result.pendingPlaceLookups)
        ledger = updated
        ledgerLabelCount = updated.resolvedCount
        placeReport = report

        // Two reasons to stop with the labels and nothing else. The library may have been
        // rebuilt or narrowed while the provider was answering, in which case recomposing
        // from the index this call started with would put back records the new grant may
        // not cover. Or the person left the day, in which case a full recomposition is
        // work nobody is waiting for.
        guard !report.wasCancelled, !Task.isCancelled else {
            // A label that did land is owed to this day: the coordinate is answered now,
            // so nothing would ask again and the cached day would stay unnamed forever.
            if report.resolved > 0 || report.unlabelled > 0 { cache.invalidate(date) }
            return
        }
        guard libraryGeneration == generation, let current = self.index else { return }

        // Every composed day may now carry a label it did not have, so the composed
        // window is rebuilt rather than left to recompose a row at a time while it is
        // being laid out.
        cache.invalidateAll()
        await composeBackfill(index: current)
        guard libraryGeneration == generation else { return }
        var credits = Set(placeAttributions.map(ResolvedPlaceLabel.creditKey))
        for line in day(for: date).placeAttributions
        where credits.insert(ResolvedPlaceLabel.creditKey(line)).inserted {
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
