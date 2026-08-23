import Foundation
import Testing
import UIKit
@testable import rmbr

/// What happens to a library rmbr may no longer read.
///
/// Photo access is changed outside rmbr, so the rules that matter here are all about what
/// is true across a suspension point: the moment the grant narrows, everything built from
/// the old one has to be gone before anything else can run, and work already walking the
/// old library must publish nothing. Every one of them is exercised against a library the
/// test supplies, through gates the test opens itself, so nothing here waits on a clock,
/// on a real photo library or on a network.
@MainActor
@Suite("Library invalidation")
struct LibraryInvalidationTests {

    // MARK: - Harness

    /// A suspension the test owns: work stops here until it is let go.
    private actor Gate {
        private var reached: CheckedContinuation<Void, Never>?
        private var hasReached = false
        private var release: CheckedContinuation<Void, Never>?
        private var isOpen = false

        /// Called by the code under test.
        func enter() async {
            hasReached = true
            reached?.resume()
            reached = nil
            guard !isOpen else { return }
            await withCheckedContinuation { release = $0 }
        }

        func waitUntilReached() async {
            guard !hasReached else { return }
            await withCheckedContinuation { reached = $0 }
        }

        func open() {
            isOpen = true
            release?.resume()
            release = nil
        }
    }

    /// What Settings currently says, readable from the load's own thread.
    private final class Grant: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PhotoLibraryAccess

        init(_ value: PhotoLibraryAccess) { self.value = value }

        var current: PhotoLibraryAccess {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private actor Calls {
        private var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    /// A photo library the test supplies, stoppable at each point a load can be overtaken.
    private struct Fake {
        let grant: Grant
        let snapshotRead: Gate
        let walk: Gate
        let snapshotWrite: Gate
        let beforeCommit: Gate
        let source: LibrarySource
    }

    private nonisolated static let signature = LibrarySignature(
        assetCount: 2,
        newestCreationDate: nil,
        selectionFingerprint: nil
    )

    /// Two places far enough apart to be separate anchors, and to need separate lookups.
    private nonisolated static let firstPlace = Coordinate(latitude: 41.8757, longitude: -87.6580)
    private nonisolated static let secondPlace = Coordinate(latitude: 41.9000, longitude: -87.6200)

    private static func captures() -> [CaptureRecord] {
        let today = LocalDate(instant: Date(), in: .current)
        return [
            Fixture.capture("09:00:00", on: today, in: .current,
                            coordinate: firstPlace, identifier: "a"),
            Fixture.capture("09:05:00", on: today, in: .current,
                            coordinate: firstPlace, identifier: "b")
        ]
    }

    /// The walk and the write report figures a test can recognise, so a run that was
    /// overtaken can be told apart from the run that was allowed to publish.
    private nonisolated static func walkMetrics(call: Int) -> IndexRunMetrics {
        var metrics = IndexRunMetrics()
        metrics.assetCount = call * 100
        return metrics
    }

    private static func fake(
        _ access: PhotoLibraryAccess,
        records: [CaptureRecord]? = nil,
        holdSnapshotReadFromCall: Int? = nil,
        holdWalkFromCall: Int? = nil,
        emitStaleProgress: Bool = false,
        holdSnapshotWriteFromCall: Int? = nil,
        holdBeforeCommit: Bool = false
    ) -> Fake {
        let grant = Grant(access)
        let snapshotRead = Gate()
        let walk = Gate()
        let snapshotWrite = Gate()
        let beforeCommit = Gate()
        let reads = Calls()
        let walks = Calls()
        let writes = Calls()
        let walked = records ?? captures()

        var source = LibrarySource()
        source.authorization = { grant.current }
        source.requestAuthorization = { grant.current }
        source.signature = { _ in signature }
        source.loadSnapshot = {
            let call = await reads.next()
            if let holdSnapshotReadFromCall, call >= holdSnapshotReadFromCall {
                await snapshotRead.enter()
            }
            return nil
        }
        source.buildIndex = { _, progress in
            let call = await walks.next()
            if let holdWalkFromCall, call >= holdWalkFromCall {
                // Held after the walk has read the library, which is where a grant that
                // narrows leaves a walk holding records it may no longer publish.
                await walk.enter()
                if emitStaleProgress { progress(call * 100, call * 100) }
            }
            return PhotoLibraryIndexer.Output(records: walked, metrics: walkMetrics(call: call))
        }
        source.saveSnapshot = { _ in
            let call = await writes.next()
            if let holdSnapshotWriteFromCall, call >= holdSnapshotWriteFromCall {
                await snapshotWrite.enter()
            }
            return Double(call) * 10
        }
        if holdBeforeCommit {
            source.beforeCommit = { await beforeCommit.enter() }
        }

        return Fake(
            grant: grant,
            snapshotRead: snapshotRead,
            walk: walk,
            snapshotWrite: snapshotWrite,
            beforeCommit: beforeCommit,
            source: source
        )
    }

    /// Answers lookups from a fixed table, with no key, no network and no throttle.
    private actor StubResolver: PlaceResolving {
        private var ledger: PlaceLabelLedger
        private let answers: [(Coordinate, ResolvedPlaceLabel)]
        private let reportsCancelled: Bool
        private(set) var requestedCoordinates: [Coordinate] = []

        init(
            seeded: [(Coordinate, ResolvedPlaceLabel)] = [],
            answering answers: [(Coordinate, ResolvedPlaceLabel)] = [],
            reportsCancelled: Bool = false
        ) {
            var ledger = PlaceLabelLedger()
            for (coordinate, label) in seeded { ledger.record(.resolved(label), at: coordinate) }
            self.ledger = ledger
            self.answers = answers
            self.reportsCancelled = reportsCancelled
        }

        var currentLedger: PlaceLabelLedger { ledger }

        func persistPendingLabels() -> Bool { true }

        func resolve(
            _ lookups: [PendingPlaceLookup]
        ) -> (PlaceLabelLedger, PlaceResolutionReport) {
            var report = PlaceResolutionReport()
            report.requested = lookups.count
            for lookup in lookups {
                requestedCoordinates.append(lookup.coordinate)
                guard let label = answers.first(where: {
                    $0.0.distance(to: lookup.coordinate) <= PlaceLabelLedger.matchDistanceMetres
                })?.1 else { continue }
                ledger.record(.resolved(label), at: lookup.coordinate)
                report.resolved += 1
            }
            report.wasCancelled = reportsCancelled
            return (ledger, report)
        }
    }

    /// How many requests have been issued, so a test can wait for the one it means.
    private actor RequestLog {
        private var count = 0
        private var waiting: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func record() {
            count += 1
            waiting.removeAll { entry in
                guard count >= entry.target else { return false }
                entry.continuation.resume()
                return true
            }
        }

        func wait(until target: Int) async {
            guard count < target else { return }
            await withCheckedContinuation { waiting.append((target, $0)) }
        }
    }

    /// PhotoKit, replaced by something a test can answer for.
    @MainActor
    private final class StubImageSource: ThumbnailImageSource {
        var resolvable: [String] = []
        private(set) var cancelled: [Int] = []
        private(set) var releases = 0
        private(set) var stoppedCaching: [[String]] = []
        private var deliveries: [Int: @MainActor (ThumbnailUpdate) -> Void] = [:]
        private var nextRequestID = 0
        let issued = RequestLog()

        func resolve(_ identifiers: [String]) async -> [String] {
            identifiers.filter { resolvable.contains($0) }
        }

        func requestImage(
            identifier: String,
            targetSize: CGSize,
            allowNetwork: Bool,
            deliver: @escaping @MainActor (ThumbnailUpdate) -> Void
        ) -> Int {
            nextRequestID += 1
            deliveries[nextRequestID] = deliver
            let log = issued
            Task { await log.record() }
            return nextRequestID
        }

        func cancel(_ requestID: Int) { cancelled.append(requestID) }

        func startCaching(_ identifiers: [String], targetSize: CGSize) {}

        func stopCaching(_ identifiers: [String], targetSize: CGSize) {
            stoppedCaching.append(identifiers)
        }

        func releaseResolved() {
            releases += 1
            resolvable = []
        }

        /// Answers a request the way PhotoKit would.
        func deliver(_ image: UIImage, forRequest requestID: Int) {
            deliveries[requestID]?(.image(image, isDegraded: false))
        }
    }

    /// What a view holds while it draws, as `MediaThumbnail` does.
    @MainActor
    private final class ViewState {
        var delivered: DeliveredImage?
    }

    // MARK: - Invalidation

    @Test("A grant that narrows during a load takes the old library down before returning")
    func narrowingDuringLoadInvalidatesWithoutSuspending() async {
        let fake = Self.fake(.full, holdSnapshotReadFromCall: 2)
        let model = LibraryModel(
            source: fake.source,
            resolver: StubResolver(seeded: [(Self.firstPlace, Fixture.label("Van Buren Lofts"))])
        )
        let today = model.today

        await model.start()
        #expect(model.phase == .ready)
        #expect(model.hasCommittedIndex)
        #expect(!model.lifeEntries.isEmpty)
        #expect(model.indexedRecordCount == 2)
        #expect(!model.day(for: today).moments.isEmpty)
        // The month row's descriptor comes from the archive survey, not from a composition.
        let described = model.summary(for: today)
        #expect(described.counts.accessibleCaptureCount == 2)
        #expect(described.placeName == "Van Buren Lofts")
        #expect(!described.attributions.isEmpty)
        let generation = model.libraryGeneration
        let pixels = model.thumbnails.generation

        // A foreground check that finds the same grant, held open at the snapshot read.
        let reload = Task { await model.refresh() }
        await fake.snapshotRead.waitUntilReached()
        #expect(model.phase == .ready)
        #expect(!model.lifeEntries.isEmpty)

        // The grant narrows while that load is still suspended. This path has no
        // suspension of its own, so everything derived from the old grant is gone by the
        // time it returns - which is what the photographs still on screen depend on.
        fake.grant.current = .limited
        await model.refresh()

        #expect(model.libraryGeneration > generation)
        #expect(model.thumbnails.generation > pixels)
        #expect(model.phase == .checkingPermission)
        #expect(!model.hasCommittedIndex)
        #expect(model.lifeEntries.isEmpty)
        #expect(model.monthEntries.isEmpty)
        #expect(model.placeAttributions.isEmpty)
        #expect(model.indexedRecordCount == 0)
        // The composed day went with it, rather than being served from the cache.
        #expect(model.day(for: today).moments.isEmpty)
        // And so did the survey signals every month row is described from: a stale count,
        // headline or credit here would outlive the library it was measured from.
        let stale = model.summary(for: today)
        #expect(stale.counts.accessibleCaptureCount == 0)
        #expect(stale.placeName == nil)
        #expect(stale.attributions.isEmpty)

        await fake.snapshotRead.open()
        await reload.value
    }

    @Test("A load walking a library rmbr may no longer read publishes nothing")
    func revokedGrantDuringLoadPublishesNothing() async {
        let fake = Self.fake(.full, holdSnapshotReadFromCall: 2)
        let model = LibraryModel(source: fake.source, resolver: StubResolver())

        await model.start()
        #expect(model.indexedRecordCount == 2)

        let reload = Task { await model.refresh() }
        await fake.snapshotRead.waitUntilReached()

        fake.grant.current = .denied
        await model.refresh()
        await fake.snapshotRead.open()
        await reload.value

        // The load that was running under the old grant reaches its commit points after
        // the generation has moved, so none of what it walked is ever served.
        #expect(model.access == .denied)
        #expect(model.phase == .permissionRefused(.denied))
        #expect(!model.hasCommittedIndex)
        #expect(model.indexedRecordCount == 0)
        #expect(model.lifeEntries.isEmpty)
    }

    @Test("A walk overtaken by a narrowed grant publishes neither records nor progress")
    func staleWalkPublishesNothing() async {
        // Held inside the walk, and again at the next snapshot read so the test can look
        // at the model after the overtaken walk has finished reporting.
        let fake = Self.fake(
            .full,
            holdSnapshotReadFromCall: 3,
            holdWalkFromCall: 2,
            emitStaleProgress: true
        )
        let model = LibraryModel(source: fake.source, resolver: StubResolver())

        await model.start()
        #expect(model.metrics?.assetCount == 100)

        let reload = Task { await model.refresh() }
        await fake.walk.waitUntilReached()

        fake.grant.current = .limited
        await model.refresh()

        // Released, the walk reports its progress and hands back the records it read from
        // the library as it was. Both belong to a grant that has since gone.
        await fake.walk.open()
        await fake.snapshotRead.waitUntilReached()

        // Its progress would have read 200 of 200 captures.
        #expect(model.phase == .checkingPermission)
        #expect(model.metrics?.assetCount == 100)
        #expect(model.indexedRecordCount == 0)
        #expect(model.lifeEntries.isEmpty)
        #expect(!model.hasCommittedIndex)

        await fake.snapshotRead.open()
        await reload.value
    }

    @Test("A run overtaken while its snapshot is being written reports no figures")
    func staleSaveRepublishesNothing() async {
        let fake = Self.fake(.full, holdSnapshotWriteFromCall: 2)
        let model = LibraryModel(source: fake.source, resolver: StubResolver())

        await model.start()
        #expect(model.metrics?.persistSeconds == 10)

        let reload = Task { await model.refresh() }
        await fake.snapshotWrite.waitUntilReached()

        fake.grant.current = .denied
        await model.refresh()
        await fake.snapshotWrite.open()
        await reload.value

        // The second write cost 20 seconds. Reporting it would be reporting a run whose
        // library rmbr is no longer allowed to read.
        #expect(model.metrics?.persistSeconds != 20)
        #expect(model.phase == .permissionRefused(.denied))
        #expect(!model.hasCommittedIndex)
    }

    // MARK: - What leaves the device

    @Test("A reconstruction that has not been committed asks the provider for nothing")
    func uncommittedIndexResolvesNoPlaceNames() async {
        let fake = Self.fake(.full, holdSnapshotWriteFromCall: 2)
        let resolver = StubResolver()
        let model = LibraryModel(source: fake.source, resolver: resolver)
        let today = model.today

        await model.start()
        let asked = await resolver.requestedCoordinates.count

        // Held while the snapshot is being written: the walk is done and its index is
        // installed, but it has not been checked against the grant that is current now, so
        // this run may still be thrown away. A coordinate sent from it cannot be recalled.
        let reload = Task { await model.refresh() }
        await fake.snapshotWrite.waitUntilReached()
        #expect(model.indexedRecordCount == 2)
        #expect(!model.hasCommittedIndex)

        await model.resolvePlaceNames(for: today)
        #expect(await resolver.requestedCoordinates.count == asked)

        await fake.snapshotWrite.open()
        await reload.value
    }

    @Test("The token a day page resolves against moves only once a run is committed")
    func committedRevisionMovesOnlyWhenAReconstructionLands() async {
        let fake = Self.fake(.full, holdSnapshotWriteFromCall: 2)
        let model = LibraryModel(source: fake.source, resolver: StubResolver())

        await model.start()
        let committed = model.committedRevision

        let reload = Task { await model.refresh() }
        // The walk is done and the index is installed, but the run has not been checked
        // against the grant yet, so nothing may be asked of it.
        await fake.snapshotWrite.waitUntilReached()
        #expect(model.committedRevision == committed + 1)
        #expect(!model.hasCommittedIndex)

        await fake.snapshotWrite.open()
        await reload.value
        #expect(model.hasCommittedIndex)
        #expect(model.committedRevision > committed + 1)
    }

    // MARK: - Pixels

    @Test("A purge takes back every pixel, request and asset the old grant produced")
    func purgeReleasesEverythingFromTheOldGrant() async {
        let source = StubImageSource()
        source.resolvable = ["a", "b"]
        let store = ThumbnailStore(source: source)
        let records = Self.captures()
        let shown = records[0].mediaReference()
        let pending = records[1].mediaReference()
        let size = CGSize(width: 200, height: 200)
        let held = ViewState()
        let generation = store.generation

        // One capture is drawn, exactly as a thumbnail draws it.
        let drawing = Task {
            for await update in store.deliveries(for: shown, targetSize: size) {
                guard case .image(let image, _) = update else { continue }
                held.delivered = DeliveredImage(image: image, generation: generation)
            }
        }
        await source.issued.wait(until: 1)
        source.deliver(UIImage(), forRequest: 1)
        await drawing.value
        #expect(store.visibleImage(held.delivered) != nil)
        #expect(store.cachedImage(for: shown, targetSize: size) != nil)

        // And another is still being fetched when the grant ends.
        let waiting = Task {
            for await _ in store.deliveries(for: pending, targetSize: size) {}
        }
        await source.issued.wait(until: 2)

        store.purge()

        // Nothing from the old grant is available to draw, to finish, or to resolve
        // again - and none of it waits on a view noticing.
        #expect(store.visibleImage(held.delivered) == nil)
        #expect(store.cachedImage(for: shown, targetSize: size) == nil)
        #expect(!source.cancelled.isEmpty)
        #expect(source.releases == 1)
        #expect(source.resolvable.isEmpty)
        await waiting.value
    }

    // MARK: - Ledger ordering

    @Test("A label answered later survives a composition that started before it")
    func newerLabelSurvivesAnOlderComposition() async {
        let today = LocalDate(instant: Date(), in: .current)
        let yesterday = today.adding(days: -1, in: .current)
        let records = [
            Fixture.capture("09:00:00", on: today, in: .current,
                            coordinate: Self.firstPlace, identifier: "a"),
            Fixture.capture("18:00:00", on: today, in: .current,
                            coordinate: Self.secondPlace, identifier: "b"),
            Fixture.capture("11:00:00", on: yesterday, in: .current,
                            coordinate: Self.secondPlace, identifier: "c")
        ]
        let first = Fixture.label("Van Buren Lofts")
        let second = Fixture.label("Millennium Park")
        let resolver = StubResolver(
            answering: [(Self.firstPlace, first), (Self.secondPlace, second)],
            reportsCancelled: true
        )
        let fake = Self.fake(.full, records: records, holdBeforeCommit: true)
        let model = LibraryModel(source: fake.source, resolver: resolver)

        await model.start()
        #expect(model.hasCommittedIndex)

        // The first lookup answers one anchor and its recomposition is held just before it
        // commits, with a ledger that does not know the second place yet.
        let older = Task { await model.resolvePlaceNames(for: today) }
        await fake.beforeCommit.waitUntilReached()

        // The second lookup lands while it waits, and stores a label the held composition
        // was never built with.
        await model.resolvePlaceNames(for: yesterday)

        await fake.beforeCommit.open()
        await older.value

        // The label that arrived last is the one on the day, and it is credited.
        let named = model.day(for: yesterday)
        #expect(named.moments.first?.place?.label.knownValue?.text == "Millennium Park")
        #expect(!named.placeAttributions.isEmpty)
        #expect(model.placeAttributions.contains(OpenStreetMap.attribution))
    }
}
