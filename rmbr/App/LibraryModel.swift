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

    /// Whether this day belongs to the composed schedule rather than to what was opened.
    func isScheduled(_ date: LocalDate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduled.contains(date.description)
    }

    func contains(_ date: LocalDate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage[date.description] != nil
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

/// Everything the model reads that is not its own state.
///
/// In the app this is PhotoKit and the snapshot on disk. It is a value of closures
/// rather than a set of calls to globals so that the invalidation and generation rules -
/// which are entirely about what happens across a suspension point - can be exercised
/// against a library a test supplies and a load a test can hold open.
struct LibrarySource: Sendable {
    /// Confirming the snapshot directory is excluded from backup touches the file system,
    /// so the store that does it is resolved once rather than on every read and write.
    private static let snapshotStore = CaptureIndexStore()

    var authorization: @Sendable () -> PhotoLibraryAccess = { PhotoLibraryAuthorization.current }

    var requestAuthorization: @Sendable () async -> PhotoLibraryAccess = {
        await PhotoLibraryAuthorization.request()
    }

    var signature: @Sendable (_ coversWholeLibrary: Bool) async -> LibrarySignature = {
        PhotoLibraryIndexer.librarySignature(coversWholeLibrary: $0)
    }

    var loadSnapshot: @Sendable () async -> CaptureIndexSnapshot? = { snapshotStore.load() }

    /// Answers what writing the snapshot cost, and zero when it could not be written.
    var saveSnapshot: @Sendable (CaptureIndexSnapshot) async -> Double = {
        (try? snapshotStore.save($0)) ?? 0
    }

    var buildIndex: @Sendable (
        TimeZone, @escaping PhotoLibraryIndexer.ProgressHandler
    ) async throws -> PhotoLibraryIndexer.Output = {
        try PhotoLibraryIndexer(timeZone: $0).buildIndex(progress: $1)
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
    /// Bumped whenever the installed index changes - dropped by an invalidation, or
    /// replaced by a load that committed. Work that only makes sense against an index
    /// belongs to one revision of it, and runs again when this moves.
    private(set) var indexRevision = 0

    /// Owned rather than observed, so that dropping the library and dropping the pixels
    /// drawn from it are one operation and cannot be separated by a suspension point.
    let thumbnails = ThumbnailStore()

    let tuning = ReconstructionTuningProfile.v1
    private let source: LibrarySource
    private let composer: DayComposer
    private let resolver = PlaceNameResolver()
    private let credentials = GeoapifyCredentialStore()
    private let cache = DayCache()

    private var index: CaptureIndex?
    private var ledger = PlaceLabelLedger()
    /// Bumped whenever the ledger is replaced. A composition carries the labels the
    /// ledger held when it started, so a pass that ran across a newer answer describes
    /// names that have since been superseded and must not be committed over them.
    private var ledgerRevision = 0
    private var representativeDates: Set<LocalDate> = []
    private var placeRequestsInFlight: Set<String> = []
    /// Coordinates whose newly stored labels the cached days do not carry yet, and
    /// whether a pass is already draining them. One pass at a time is what stops two
    /// lookups composing the same days against two different ledgers.
    private var pendingRefreshCoordinates: [Coordinate] = []
    private var isRefreshingDays = false
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

    init(source: LibrarySource = LibrarySource()) {
        self.source = source
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

    /// Whether a reconstruction is committed and a day may be described from it.
    ///
    /// A day composed while the index is being rebuilt would be composed from no records
    /// at all, and would read as a day that held nothing. A surface asks this first and
    /// says rmbr is reading rather than printing that answer.
    var hasCommittedIndex: Bool { index != nil && phase == .ready }

    // MARK: - Lifecycle

    func start() async {
        hasStarted = true
        access = source.authorization()
        hasPlaceCredential = credentials.hasKey
        adoptLedger(await resolver.currentLedger)

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

        // Read and act on the grant before anything suspends, and before the busy check:
        // a load already running is the case that most needs the old library taken down,
        // because it is the case that leaves it on screen the longest. Full to limited
        // narrows what may be shown, and limited to full changes what every count means; a
        // limited grant can also be re-chosen without the enum moving at all, and finding
        // that out means reading the new selection, which must not happen while
        // photographs the person may have just revoked are still visible.
        let current = source.authorization()
        hasPlaceCredential = credentials.hasKey
        let changed = current != access
        access = current
        if changed || current == .limited { invalidateLibrary() }

        // A load in flight was built against the grant that has just gone. It reads the
        // generation at each of its own suspension points and publishes nothing once this
        // one has moved, so the queued pass is what indexes whatever rmbr may see now.
        guard !isLoading else {
            refreshPending = true
            return
        }

        // A label that only reached memory last time is still owed to the ledger.
        if await resolver.persistPendingLabels() { placeReport.labelsPersisted = true }

        switch current {
        case .notDetermined:
            phase = .awaitingPermission
        case .denied, .restricted:
            phase = .permissionRefused(current)
        case .full, .limited:
            await loadOrBuildIndex()
        }
    }

    /// Drops everything built from the library as rmbr was allowed to see it.
    ///
    /// The single invalidation in the app, and synchronous on purpose. Photo access is
    /// changed outside rmbr, so every entry point - a foreground check on the idle path or
    /// over a running load, an authorisation change, a re-chosen limited selection, a
    /// rebuild from the diagnostics sheet - comes through here, and it runs to completion
    /// before the next suspension point. Anything spread across an actor hop or a SwiftUI
    /// callback, which cannot run until the main actor yields, leaves photographs from a
    /// grant that no longer exists on screen in the meantime.
    ///
    /// One generation ends here and everything derived from it goes with it: the index and
    /// the rows and signals built from it, the composed days, and every pixel, resolved
    /// asset, in-flight request and preheated window the thumbnail store still holds.
    private func invalidateLibrary() {
        libraryGeneration += 1
        indexRevision += 1
        index = nil
        pendingRefreshCoordinates = []
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
        thumbnails.purge()
        // There is nothing left to draw a day from, and staying ready over that would
        // print an empty life - a claim that the library is empty rather than that rmbr is
        // reading it again. The surface says so until a reconstruction commits.
        phase = .checkingPermission
    }

    func requestAccess() async {
        access = await source.requestAuthorization()
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
            let source = source
            let wantsExhaustive = access.isExhaustive
            let generation = libraryGeneration
            let warm = await Task.detached(priority: .userInitiated) {
                () -> (CaptureIndexSnapshot, LibrarySignature)? in
                guard let snapshot = await source.loadSnapshot(),
                      snapshot.wasFullAccess == wantsExhaustive else { return nil }
                // Under a limited grant the signature also fingerprints which assets the
                // grant covers, so swapping one chosen photograph for another is seen.
                return (snapshot, await source.signature(wantsExhaustive))
            }.value

            // A grant that moved while the snapshot was being read took the library this
            // was resolving down with it, so none of it describes what rmbr may see now.
            guard libraryGeneration == generation else {
                refreshPending = true
                return
            }

            if let (snapshot, signature) = warm, signature == snapshot.signature {
                // Coming back to the foreground with the same library, on the same day,
                // has nothing to redo: the survey and the composed window still describe
                // what is on screen.
                if index != nil, currentSignature == signature, builtForDay == today,
                   phase == .ready {
                    return
                }
                // Installed into an emptied model, in one main-actor turn: nothing from
                // the previous generation is still being served when this one starts.
                invalidateLibrary()
                index = snapshot.index
                indexRevision += 1
                metrics = snapshot.metrics
                indexBuiltAt = snapshot.builtAt
                loadedFromCache = true
                currentSignature = signature
                await finishIndexing()
                return
            }
        }

        // Reaching here means no cached snapshot describes what rmbr may currently see -
        // the grant narrowed, the selection changed, the library moved, or a rebuild was
        // asked for. Whatever was built from the old one stops being served now, not when
        // the rebuild lands.
        invalidateLibrary()

        loadedFromCache = false
        phase = .indexing(done: 0, total: 0)
        let generation = libraryGeneration

        let timeZone = TimeZone.current
        // A walk that has been overtaken keeps counting, and its progress describes a
        // library that is no longer being served. It reports nothing once that happens.
        let progress: PhotoLibraryIndexer.ProgressHandler = { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self, self.libraryGeneration == generation else { return }
                self.phase = .indexing(done: done, total: total)
            }
        }

        let source = source
        let wantsExhaustive = access.isExhaustive
        do {
            // The walk and the signature are separate PhotoKit reads, so the selection
            // could move between them and leave records described by a fingerprint they
            // do not belong to. Bracketing the walk is what makes the pair consistent.
            let walked = try await Task.detached(priority: .userInitiated) {
                () -> (PhotoLibraryIndexer.Output, LibrarySignature)? in
                let before = await source.signature(wantsExhaustive)
                let output = try await source.buildIndex(timeZone, progress)
                let after = await source.signature(wantsExhaustive)
                guard before == after else { return nil }
                return (output, after)
            }.value

            // The library changed under the walk, or the grant went while it ran. Nothing
            // from it is published, and the queued pass indexes what the grant covers now.
            guard let (output, signature) = walked, libraryGeneration == generation else {
                refreshPending = true
                return
            }
            let built = CaptureIndex(records: output.records, timeZone: timeZone)
            index = built
            indexRevision += 1
            metrics = output.metrics
            indexBuiltAt = Date()
            currentSignature = signature
            // Anything composed while the walk ran was composed against no index at all.
            cache.invalidateAll()

            let snapshot = CaptureIndexSnapshot(
                builtAt: Date(),
                engineVersion: ReconstructionVersion.engine,
                index: built,
                metrics: output.metrics,
                wasFullAccess: access.isExhaustive,
                signature: signature
            )
            let persistSeconds = await source.saveSnapshot(snapshot)
            // A grant that went while the snapshot was being written took this run's
            // figures with it; they describe a library that is no longer on screen.
            guard libraryGeneration == generation else {
                refreshPending = true
                return
            }
            // The reported total is what the run cost, persistence included, both here
            // and in the snapshot a later warm launch reads back.
            var measured = output.metrics
            measured.persistSeconds = persistSeconds
            metrics = measured

            await finishIndexing()
        } catch is CancellationError {
            guard libraryGeneration == generation else { return }
            phase = .failed("Indexing was cancelled.")
        } catch {
            guard libraryGeneration == generation else { return }
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
        let generation = libraryGeneration
        let survey = await Task.detached(priority: .userInitiated) {
            ArchiveSurveyor.survey(index: index, tuning: tuning)
        }.value
        // The grant went while the archive was being surveyed, so these rows describe a
        // library rmbr is no longer allowed to read. None of them reaches the surface.
        guard libraryGeneration == generation else {
            refreshPending = true
            return
        }
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
        let latestSignature = await source.signature(wantsExhaustive)
        guard !refreshPending,
              libraryGeneration == generation,
              source.authorization() == access,
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
        let hasFullAccess = access.isExhaustive
        let timeZone = index.timeZone

        while true {
            let generation = libraryGeneration
            let revision = ledgerRevision
            let placeLabels = ledger.lookup

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
            // composed describes records rmbr may no longer be allowed to show. Either way
            // it is dropped without ever being stored.
            guard let outcome, !Task.isCancelled, libraryGeneration == generation else { return }
            // A lookup answered while this pass composed, so these days are named by a
            // ledger that has already been superseded. Committing them would take a label
            // back off a day that will never ask for it again, the coordinate being
            // answered; the window is composed again against the ledger as it is now.
            guard ledgerRevision == revision else { continue }

            cache.clearSchedule()
            for day in outcome.0 { cache.store(day, scheduled: true) }
            composedDayCount = dates.count
            composeSeconds = outcome.1
            placeAttributions = outcome.2
            return
        }
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
        // Keyed to the index it is asking about, so a lookup still in flight against a
        // library that has been replaced cannot stop this day being resolved again.
        let key = "\(indexRevision):\(date.description)"
        guard !placeRequestsInFlight.contains(key) else { return }
        placeRequestsInFlight.insert(key)
        defer { placeRequestsInFlight.remove(key) }

        let generation = libraryGeneration
        let (updated, report) = await resolver.resolve(result.pendingPlaceLookups)
        adoptLedger(updated)
        placeReport = report

        let answered = result.pendingPlaceLookups.map(\.coordinate)
        let landed = report.resolved > 0 || report.unlabelled > 0
        // The library may have been rebuilt or narrowed while the provider was answering,
        // or the person may have left the day. Either way the full window rebuild below is
        // not run - but what did land is still carried into every day it names, against
        // whichever index is current now, because the coordinate is answered and nothing
        // would ever ask about it again.
        let stillWanted = !report.wasCancelled && !Task.isCancelled
            && libraryGeneration == generation

        guard let current = self.index else { return }
        // Days these coordinates name are brought up to date first, so a scheduled row is
        // replaced in place rather than dropped: the composed window stays whole until the
        // rebuild below can commit its replacement, and a rebuild that gets cancelled
        // cannot leave Life composing a row while it is being laid out.
        if landed { await refreshDays(near: answered, index: current) }
        guard stillWanted, libraryGeneration == generation, let current = self.index else {
            return
        }

        await composeBackfill(index: current)
        guard libraryGeneration == generation else { return }
        mergeAttributions(from: day(for: date))
    }

    /// Recomposes every cached day the newly answered coordinates name.
    ///
    /// One anchor can be the place of many days, and a day already composed without the
    /// label would keep that composition forever: the ledger answers the coordinate now,
    /// so no later composition would ask for it again. A scheduled day is replaced in
    /// place, which is what keeps the composed window whole.
    private func refreshDays(near coordinates: [Coordinate], index: CaptureIndex) async {
        guard !coordinates.isEmpty else { return }
        pendingRefreshCoordinates.append(contentsOf: coordinates)
        // One pass drains the queue. A day page open beside this one can answer its own
        // coordinates at the same time, and two passes composing the same days against two
        // different ledgers would race to commit; queued behind this one, the later
        // coordinates are answered by a pass that reads the ledger after both have landed.
        guard !isRefreshingDays else { return }
        isRefreshingDays = true
        defer { isRefreshingDays = false }

        let composer = composer
        let cache = cache
        let signals = signalsByDate
        let hasFullAccess = access.isExhaustive
        let timeZone = index.timeZone

        while !pendingRefreshCoordinates.isEmpty {
            let coordinates = pendingRefreshCoordinates
            let generation = libraryGeneration
            let revision = ledgerRevision
            let placeLabels = ledger.lookup

            // A frequently visited anchor is the place of hundreds of days, so finding
            // them and composing them again happens away from the main actor and is
            // committed only once the library and the ledger are confirmed to be the ones
            // they were composed against.
            let refreshed = await Task.detached(priority: .userInitiated) { () -> [Day] in
                let named = signals.compactMap { date, signals -> LocalDate? in
                    let touched = signals.chronologicalAnchorCentroids.contains { centroid in
                        coordinates.contains {
                            $0.distance(to: centroid) <= PlaceLabelLedger.matchDistanceMetres
                        }
                    }
                    return touched && cache.contains(date) ? date : nil
                }
                return named.map { date in
                    composer.compose(
                        date: date,
                        captures: index.records(on: date),
                        context: DayComposer.Context(
                            timeZone: timeZone,
                            hasFullLibraryAccess: hasFullAccess,
                            placeLabels: placeLabels,
                            composedAt: Date()
                        )
                    ).day
                }
            }.value

            guard libraryGeneration == generation else { return }
            // A lookup landed while this pass composed, so these days are named by a
            // superseded ledger. The coordinates stay queued and are composed again
            // against the newer one rather than being abandoned: they are already answered
            // for good, so no later lookup would ever put their labels on a day.
            guard ledgerRevision == revision else { continue }
            for day in refreshed where cache.contains(day.date) {
                cache.store(day, scheduled: cache.isScheduled(day.date))
                // A stored label may never be shown without the credits it owes, whatever
                // path put it on screen.
                mergeAttributions(from: day)
            }
            pendingRefreshCoordinates.removeFirst(coordinates.count)
        }
    }

    private func adoptLedger(_ updated: PlaceLabelLedger) {
        ledger = updated
        ledgerRevision += 1
        ledgerLabelCount = updated.resolvedCount
    }

    private func mergeAttributions(from day: Day) {
        var credits = Set(placeAttributions.map(ResolvedPlaceLabel.creditKey))
        for line in day.placeAttributions
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
