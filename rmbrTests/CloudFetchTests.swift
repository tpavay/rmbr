import Foundation
import Testing
import UIKit
@testable import rmbr

/// PhotoKit's image path, replaced by something a test can answer for.
///
/// It records the permission each request carried, which is the whole of the bug behind
/// a permanently blurry hero: a request that refuses the network can only ever be
/// answered with the degraded thumbnail already on the device.
@MainActor
private final class ScriptedImageSource: ThumbnailImageSource {
    var resolvable: [String] = []
    private(set) var permissions: [Bool] = []
    private(set) var cancelled: [Int] = []
    private var deliveries: [Int: @MainActor (ThumbnailUpdate) -> Void] = [:]
    private var nextRequestID = 0

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
        permissions.append(allowNetwork)
        deliveries[nextRequestID] = deliver
        return nextRequestID
    }

    func cancel(_ requestID: Int) { cancelled.append(requestID) }
    func startCaching(_ identifiers: [String], targetSize: CGSize) {}
    func stopCaching(_ identifiers: [String], targetSize: CGSize) {}
    func releaseResolved() { resolvable = [] }

    /// Answers a request the way PhotoKit would, one pass at a time.
    func answer(_ update: ThumbnailUpdate, forRequest requestID: Int) {
        deliveries[requestID]?(update)
    }
}

@MainActor
@Suite("Fetching an original iCloud has offloaded")
struct CloudFetchTests {
    private let size = CGSize(width: 1400, height: 1800)

    private func capture(_ identifier: String, kind: MediaKind = .photo) -> MediaReference {
        Fixture.capture(
            "09:00:00",
            on: LocalDate(year: 2026, month: 8, day: 20),
            in: Fixture.chicago,
            kind: kind,
            identifier: identifier
        ).mediaReference()
    }

    /// Waits until the store has issued its nth request, which it does only after the
    /// identifier has resolved.
    private func waitForRequests(_ count: Int, on source: ScriptedImageSource) async {
        for attempt in 0..<400 {
            if source.permissions.count >= count { return }
            if attempt % 16 == 15 { try? await Task.sleep(for: .milliseconds(1)) }
            await Task.yield()
        }
        Issue.record("the store never issued request \(count)")
    }

    // MARK: The permission that caused the blur

    @Test("A surface that spends the network is the surface PhotoKit is asked with")
    func theSurfacesPermissionReachesPhotoKit() async {
        let source = ScriptedImageSource()
        source.resolvable = ["hero"]
        let store = ThumbnailStore(source: source)
        let hero = capture("hero")

        let fetching = Task {
            for await _ in store.deliveries(for: hero, targetSize: size, allowNetwork: true) {}
        }
        await waitForRequests(1, on: source)
        #expect(source.permissions == [true])

        source.answer(.image(UIImage(), isDegraded: false), forRequest: 1)
        await fetching.value

        // And a surface that refuses it is asked for exactly that, at its own size.
        let grid = Task {
            for await _ in store.deliveries(for: hero, targetSize: CGSize(width: 300, height: 300)) {}
        }
        await waitForRequests(2, on: source)
        #expect(source.permissions == [true, false])
        source.answer(.unavailable(.notFetched), forRequest: 2)
        await grid.value
    }

    @Test("A request that came back with the original still in iCloud says so and ends")
    func anOffloadedOriginalEndsWithAReasonRatherThanSilence() async {
        let source = ScriptedImageSource()
        source.resolvable = ["offloaded"]
        let store = ThumbnailStore(source: source)
        let reference = capture("offloaded")
        let degraded = UIImage()

        let fetching = Task {
            var updates: [ThumbnailUpdate] = []
            for await update in store.deliveries(for: reference, targetSize: size) {
                updates.append(update)
            }
            return updates
        }
        await waitForRequests(1, on: source)
        source.answer(.image(degraded, isDegraded: true), forRequest: 1)
        source.answer(.unavailable(.notFetched), forRequest: 1)
        let seen = await fetching.value

        #expect(seen.count == 2)
        if let opening = seen.first, case .image(_, let isDegraded) = opening {
            #expect(isDegraded)
        } else {
            Issue.record("the degraded pass never arrived")
        }
        if let ending = seen.last, case .unavailable(let reason) = ending {
            #expect(reason == .notFetched)
        } else {
            Issue.record("the wait ended in silence rather than a reason")
        }
        // The degraded pass is a placeholder, not an answer, so nothing keeps it.
        #expect(store.cachedImage(for: reference, targetSize: size) == nil)
    }

    @Test("An identifier the library will not resolve is stated rather than left waiting")
    func anUnresolvableCaptureEndsAsUnreadable() async {
        let source = ScriptedImageSource()
        let store = ThumbnailStore(source: source)

        var seen: [ThumbnailUpdate] = []
        for await update in store.deliveries(for: capture("gone"), targetSize: size) {
            seen.append(update)
        }

        #expect(seen.count == 1)
        if let only = seen.first, case .unavailable(let reason) = only {
            #expect(reason == .unreadable)
        } else {
            Issue.record("an unresolvable capture ended in silence")
        }
    }

    @Test("Only a fraction short of the whole counts as a download in progress")
    func aCompletedPassIsNotADownload() async {
        let source = ScriptedImageSource()
        source.resolvable = ["hero"]
        let store = ThumbnailStore(source: source)
        let reference = capture("hero")

        let fetching = Task {
            var fractions: [Double] = []
            for await update in store.deliveries(
                for: reference,
                targetSize: size,
                allowNetwork: true
            ) {
                if case .fetching(let fraction) = update { fractions.append(fraction) }
            }
            return fractions
        }
        await waitForRequests(1, on: source)
        // PhotoKit reports a single completed pass for an original already on the device,
        // and "fetching from iCloud, 100 per cent" about a local file is not true.
        source.answer(.fetching(0), forRequest: 1)
        source.answer(.fetching(1), forRequest: 1)
        source.answer(.fetching(0.4), forRequest: 1)
        source.answer(.image(UIImage(), isDegraded: false), forRequest: 1)

        let fractions = await fetching.value
        #expect(fractions == [0.4])
    }

    @Test("Everybody waiting on one request is told the same reason")
    func oneRequestAnswersEveryWaiter() async {
        let source = ScriptedImageSource()
        source.resolvable = ["shared"]
        let store = ThumbnailStore(source: source)
        let reference = capture("shared")

        func waiter() -> Task<CaptureUnavailability?, Never> {
            Task {
                var reason: CaptureUnavailability?
                for await update in store.deliveries(
                    for: reference,
                    targetSize: size,
                    allowNetwork: true
                ) {
                    if case .unavailable(let seen) = update { reason = seen }
                }
                return reason
            }
        }
        let first = waiter()
        let second = waiter()
        await waitForRequests(1, on: source)
        // One request for however many surfaces want it.
        #expect(source.permissions.count == 1)
        source.answer(.unavailable(.notFetched), forRequest: 1)

        let toFirst = await first.value
        let toSecond = await second.value
        #expect(toFirst == .notFetched)
        #expect(toSecond == .notFetched)
    }

    @Test("A grant that ends under a fetch cancels it rather than calling it a failure")
    func aPurgeEndsAFetchWithNothingToSay() async {
        let source = ScriptedImageSource()
        source.resolvable = ["mid-flight"]
        let store = ThumbnailStore(source: source)

        let fetching = Task {
            var reason: CaptureUnavailability?
            for await update in store.deliveries(
                for: capture("mid-flight"),
                targetSize: size,
                allowNetwork: true
            ) {
                if case .unavailable(let seen) = update { reason = seen }
            }
            return reason
        }
        await waitForRequests(1, on: source)
        store.purge()

        let reason = await fetching.value
        #expect(reason == .cancelled)
        #expect(!source.cancelled.isEmpty)
        // And a cancelled fetch is never printed at anybody.
        var state = CloudFetchState()
        state.apply(.unavailable(.cancelled))
        #expect(state.statement == nil)
    }

    // MARK: What the surface says while it waits

    @Test("A wait says nothing until it has been one")
    func aFastLocalFetchDrawsNoChrome() {
        var state = CloudFetchState()
        #expect(state.phase == .preparing(progress: nil))
        // The degraded pass is not the pixels that were asked for, so the wait is on -
        // but it is not yet worth a ring that would appear and vanish on every page.
        state.apply(.image(UIImage(), isDegraded: true))
        #expect(state.statement == nil)

        state.apply(.image(UIImage(), isDegraded: false))
        #expect(state.phase == .ready)
        #expect(state.statement == nil)
    }

    @Test("A wait that has lasted is stated, and a finished one is not")
    func aLastingWaitIsStated() {
        var waiting = CloudFetchState()
        waiting.waitBecameWorthStating()
        #expect(waiting.statement == .preparing(progress: nil))

        var arrived = CloudFetchState()
        arrived.apply(.image(UIImage(), isDegraded: false))
        arrived.waitBecameWorthStating()
        #expect(arrived.statement == nil)
    }

    @Test("A download PhotoKit reports is stated at once, with its own figure on it")
    func aReportedDownloadNeedsNoGracePeriod() {
        var state = CloudFetchState()
        state.apply(.fetching(0.42))
        #expect(state.statement == .preparing(progress: 0.42))

        // And once the pixels arrive, the ring goes with them.
        state.apply(.image(UIImage(), isDegraded: false))
        #expect(state.statement == nil)
    }

    @Test("A failure is the answer, so it is never held back")
    func aFailureIsStatedImmediately() {
        var state = CloudFetchState()
        state.apply(.unavailable(.notFetched))
        #expect(state.statement == .unavailable(.notFetched))

        var walkedAway = CloudFetchState()
        walkedAway.apply(.unavailable(.cancelled))
        #expect(walkedAway.statement == nil)
    }

    // MARK: The sentences

    @Test("Each reason is a different true sentence, in the noun the capture is")
    func theSentencesSayWhichKindOfNot() {
        #expect(
            CaptureUnavailability.notFetched.sentence(for: .photo)
                == "This photo is stored in iCloud and rmbr could not finish downloading it."
        )
        #expect(
            CaptureUnavailability.notFetched.sentence(for: .video)?.contains("This video") == true
        )
        #expect(
            CaptureUnavailability.notFetched.sentence(for: .livePhoto)?
                .contains("This Live Photo") == true
        )
        #expect(
            CaptureUnavailability.unreadable.sentence(for: .photo)
                == "rmbr could not open this photo."
        )
        // The video path prints the same sentences, because it is the same fact.
        #expect(CaptureUnavailability.unreadable.sentence == "rmbr could not open this video.")
        #expect(CaptureUnavailability.cancelled.sentence(for: .photo) == nil)
    }

    // MARK: The decision taken for each surface

    @Test("The surfaces that spend the network are the ones that account for it")
    func everySurfaceHasARule() {
        // A photograph filling a page somebody navigated to is worth a download, and
        // states the wait - without a control, because the hero's whole surface is
        // already the tap that opens the viewer.
        #expect(CloudFetchPolicy.dayHero.allowsNetwork)
        #expect(CloudFetchPolicy.dayHero.statesFetch)
        #expect(!CloudFetchPolicy.dayHero.offersRetry)

        // The viewer is the capture and nothing else, so the retry belongs there.
        #expect(CloudFetchPolicy.viewerStill.allowsNetwork)
        #expect(CloudFetchPolicy.viewerStill.statesFetch)
        #expect(CloudFetchPolicy.viewerStill.offersRetry)

        // A video's still fetches with it but says nothing: `VideoFrameControl` is
        // already drawing that frame's wait and that frame's failure.
        #expect(CloudFetchPolicy.viewerVideoFrame.allowsNetwork)
        #expect(!CloudFetchPolicy.viewerVideoFrame.statesFetch)

        // And the surfaces somebody scrolls past do not spend somebody's data.
        for browsing in [CloudFetchPolicy.lifeCard, .monthCell, .dayGridCell] {
            #expect(!browsing.allowsNetwork)
            #expect(!browsing.statesFetch)
        }
    }
}
