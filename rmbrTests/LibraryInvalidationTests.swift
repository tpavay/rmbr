import Foundation
import Testing
import UIKit
@testable import rmbr

/// What happens to a library rmbr may no longer read.
///
/// Photo access is changed outside rmbr, so the rules that matter here are all about
/// what is true across a suspension point: the moment the grant narrows, everything
/// built from the old one has to be gone before anything else can run, and a load that
/// was already walking the old library must publish nothing. Both are exercised against
/// a library the test supplies and a load the test holds open, so nothing here waits on
/// a clock or on a real photo library.
@MainActor
@Suite("Library invalidation")
struct LibraryInvalidationTests {
    /// A suspension the test owns: the load stops here until it is let go.
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

    private nonisolated static let signature = LibrarySignature(
        assetCount: 2,
        newestCreationDate: nil,
        selectionFingerprint: nil
    )

    private static func captures() -> [CaptureRecord] {
        let today = LocalDate(instant: Date(), in: .current)
        return [
            Fixture.capture("09:00:00", on: today, in: .current, identifier: "a"),
            Fixture.capture("09:05:00", on: today, in: .current, identifier: "b")
        ]
    }

    /// A model whose second snapshot read stops at the gate, so the second load can be
    /// held open across the moment the grant changes.
    private static func model(grant: Grant, gate: Gate) -> LibraryModel {
        let calls = Calls()
        let records = captures()
        var source = LibrarySource()
        source.authorization = { grant.current }
        source.requestAuthorization = { grant.current }
        source.signature = { _ in signature }
        source.saveSnapshot = { _ in 0 }
        source.loadSnapshot = {
            if await calls.next() == 2 { await gate.enter() }
            return nil
        }
        source.buildIndex = { _, _ in
            PhotoLibraryIndexer.Output(records: records, metrics: IndexRunMetrics())
        }
        return LibraryModel(source: source)
    }

    @Test("A grant that narrows during a load takes the old library down before returning")
    func narrowingDuringLoadInvalidatesWithoutSuspending() async {
        let grant = Grant(.full)
        let gate = Gate()
        let model = Self.model(grant: grant, gate: gate)
        let today = model.today

        await model.start()
        #expect(model.phase == .ready)
        #expect(model.hasCommittedIndex)
        #expect(!model.lifeEntries.isEmpty)
        #expect(model.indexedRecordCount == 2)
        #expect(!model.day(for: today).moments.isEmpty)
        let generation = model.libraryGeneration
        let pixels = model.thumbnails.generation

        // A foreground check that finds the same grant, held open at the snapshot read.
        let reload = Task { await model.refresh() }
        await gate.waitUntilReached()
        #expect(model.phase == .ready)
        #expect(!model.lifeEntries.isEmpty)

        // The grant narrows while that load is still suspended. This path has no
        // suspension of its own, so everything derived from the old grant is gone by the
        // time it returns - which is what the photographs still on screen depend on.
        grant.current = .limited
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

        await gate.open()
        await reload.value
    }

    @Test("A load walking a library rmbr may no longer read publishes nothing")
    func revokedGrantDuringLoadPublishesNothing() async {
        let grant = Grant(.full)
        let gate = Gate()
        let model = Self.model(grant: grant, gate: gate)

        await model.start()
        #expect(model.indexedRecordCount == 2)

        let reload = Task { await model.refresh() }
        await gate.waitUntilReached()

        grant.current = .denied
        await model.refresh()
        await gate.open()
        await reload.value

        // The load that was running under the old grant reaches its commit points after
        // the generation has moved, so none of what it walked is ever served.
        #expect(model.access == .denied)
        #expect(model.phase == .permissionRefused(.denied))
        #expect(!model.hasCommittedIndex)
        #expect(model.indexedRecordCount == 0)
        #expect(model.lifeEntries.isEmpty)
    }

    @Test("A reconstruction gives the day page a new identity to resolve against")
    func indexRevisionMovesOnDropAndOnCommit() async {
        let grant = Grant(.full)
        let gate = Gate()
        let model = Self.model(grant: grant, gate: gate)

        let atLaunch = model.indexRevision
        await model.start()
        let committed = model.indexRevision
        // Dropped once at the start of the walk, then committed.
        #expect(committed > atLaunch + 1)

        grant.current = .limited
        let reload = Task { await model.refresh() }
        await gate.waitUntilReached()
        #expect(model.indexRevision > committed)

        await gate.open()
        await reload.value
    }

    @Test("Pixels fetched under a grant that has ended are never drawn")
    func deliveredPixelsAreGenerationGated() {
        let delivered = DeliveredImage(image: UIImage(), generation: 4)
        #expect(delivered.pixels(inGeneration: 4) != nil)
        #expect(delivered.pixels(inGeneration: 5) == nil)
    }
}
