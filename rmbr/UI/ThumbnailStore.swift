import Photos
import SwiftUI
import UIKit

/// Everything the thumbnail store needs from PhotoKit.
///
/// Local identifiers are the currency rather than `PHAsset`, because a `PHAsset` cannot
/// exist without a photo library. Naming this as a protocol is what lets the behaviour
/// that matters when a grant ends - cancelling in flight requests, releasing resolved
/// assets, refusing answers that arrive afterwards - be observed on a machine with no
/// library and no permission sheet.
@MainActor
protocol ThumbnailImageSource: AnyObject {
    /// Resolves identifiers away from the main actor, answering those that resolved.
    func resolve(_ identifiers: [String]) async -> [String]

    /// Issues one request. `deliver` reports each pass with whether it is the degraded
    /// one, and nil when the request came back with nothing.
    func requestImage(
        identifier: String,
        targetSize: CGSize,
        allowNetwork: Bool,
        deliver: @escaping @MainActor (UIImage?, Bool) -> Void
    ) -> Int

    func cancel(_ requestID: Int)
    func startCaching(_ identifiers: [String], targetSize: CGSize)
    func stopCaching(_ identifiers: [String], targetSize: CGSize)

    /// Drops every asset resolved under the grant that has just ended, and refuses any
    /// resolution still in flight from before it.
    func releaseResolved()
}

/// The real library.
@MainActor
final class PhotoKitImageSource: ThumbnailImageSource {
    private let manager = PHCachingImageManager()
    private let assets = NSCache<NSString, PHAsset>()
    /// Bumped by every release. A fetch issued before one describes a grant that has
    /// since been narrowed, so its answer never reaches the cache.
    private var releases = 0

    init() {
        assets.countLimit = 1_000
    }

    /// `fetchAssets` is a Photos database read, and a scroll cannot be made to wait on
    /// one. A lookup that comes back empty is not remembered, so an asset PhotoKit failed
    /// to resolve once is asked for again the next time it appears rather than being
    /// pinned to a placeholder for the rest of the session.
    func resolve(_ identifiers: [String]) async -> [String] {
        var missing: [String] = []
        for identifier in identifiers
        where assets.object(forKey: identifier as NSString) == nil && !missing.contains(identifier) {
            missing.append(identifier)
        }

        if !missing.isEmpty {
            let issued = releases
            let wanted = missing
            let fetched = await Task.detached(priority: .userInitiated) { () -> [PHAsset] in
                let result = PHAsset.fetchAssets(withLocalIdentifiers: wanted, options: nil)
                var assets: [PHAsset] = []
                result.enumerateObjects { asset, _, _ in assets.append(asset) }
                return assets
            }.value
            guard issued == releases else { return [] }
            for asset in fetched {
                assets.setObject(asset, forKey: asset.localIdentifier as NSString)
            }
        }

        return identifiers.filter { assets.object(forKey: $0 as NSString) != nil }
    }

    func requestImage(
        identifier: String,
        targetSize: CGSize,
        allowNetwork: Bool,
        deliver: @escaping @MainActor (UIImage?, Bool) -> Void
    ) -> Int {
        guard let asset = assets.object(forKey: identifier as NSString) else {
            deliver(nil, false)
            return Int(PHInvalidImageRequestID)
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork

        let requestID = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            MainActor.assumeIsolated {
                deliver(image, (info?[PHImageResultIsDegradedKey] as? Bool) ?? false)
            }
        }
        return Int(requestID)
    }

    func cancel(_ requestID: Int) {
        manager.cancelImageRequest(PHImageRequestID(requestID))
    }

    func startCaching(_ identifiers: [String], targetSize: CGSize) {
        manager.startCachingImages(
            for: resolved(identifiers),
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

    func stopCaching(_ identifiers: [String], targetSize: CGSize) {
        manager.stopCachingImages(
            for: resolved(identifiers),
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

    func releaseResolved() {
        releases += 1
        assets.removeAllObjects()
    }

    private func resolved(_ identifiers: [String]) -> [PHAsset] {
        identifiers.compactMap { assets.object(forKey: $0 as NSString) }
    }
}

/// Delivers pixels for a media reference.
///
/// rmbr keeps no copies of anybody's photographs. Every image on screen comes from
/// PhotoKit's own cache through `PHCachingImageManager`, which is also why an
/// iCloud-only original does not stall a scroll: network access is off for inline
/// thumbnails and only turned on for a capture the person opened.
///
/// What has been decoded is held in a bounded cache the system empties under memory
/// pressure, so a long scroll through a large library never accumulates a library's
/// worth of bitmaps. Beyond that cache, the only strong reference to an image is the
/// view currently drawing it.
///
/// One request is issued per image, however many views want it, and it is cancelled the
/// moment the last of them goes away. The window around what is on screen is preheated
/// through `PHCachingImageManager` rather than by issuing speculative requests of its
/// own.
@MainActor
@Observable
final class ThumbnailStore {
    private let source: ThumbnailImageSource
    private let images = NSCache<NSString, UIImage>()
    private var inFlight: [String: Request] = [:]
    private var preheated: [String: Preheat] = [:]
    private var preheatWork: [String: Task<Void, Never>] = [:]
    /// Bumped by every purge. A fetch issued before one describes a grant that has since
    /// been narrowed, so its answer is discarded rather than allowed back into the cache,
    /// and a view holding delivered pixels of its own reads this to know they are stale.
    private(set) var generation = 0

    /// One PhotoKit request and everybody waiting on it.
    @MainActor
    private final class Request {
        var requestID: Int?
        var consumers: [UUID: AsyncStream<UIImage>.Continuation] = [:]
    }

    private struct Preheat {
        let identifiers: [String]
        let targetSize: CGSize
    }

    init(source: ThumbnailImageSource = PhotoKitImageSource()) {
        self.source = source
        images.totalCostLimit = 48 * 1024 * 1024
        images.countLimit = 200
    }

    /// What is already decoded at this size, if anything.
    func cachedImage(for reference: MediaReference, targetSize: CGSize) -> UIImage? {
        images.object(forKey: Self.key(reference.localIdentifier, targetSize) as NSString)
    }

    /// What a view holding these pixels is allowed to draw now.
    ///
    /// The generation travels with the image, so a purge stops it being drawn in the same
    /// main-actor turn rather than whenever the view's fetch gets round to restarting.
    func visibleImage(_ delivered: DeliveredImage?) -> UIImage? {
        delivered?.pixels(inGeneration: generation)
    }

    /// Every delivery PhotoKit makes for one request, the degraded pass first.
    ///
    /// The stream ends once the full-quality image has arrived or the request came back
    /// with nothing. A caller that goes away before then ends its own iteration, and the
    /// underlying request is cancelled as soon as nobody is left waiting on it.
    func deliveries(
        for reference: MediaReference,
        targetSize: CGSize,
        allowNetwork: Bool = false
    ) -> AsyncStream<UIImage> {
        let key = Self.key(reference.localIdentifier, targetSize)
        let token = UUID()
        return AsyncStream { continuation in
            let work = Task { @MainActor [weak self] in
                await self?.begin(
                    token: token,
                    key: key,
                    reference: reference,
                    targetSize: targetSize,
                    allowNetwork: allowNetwork,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [weak self] _ in
                work.cancel()
                Task { @MainActor [weak self] in
                    self?.release(token: token, key: key)
                }
            }
        }
    }

    /// Preheats a window of captures and drops whatever left it.
    ///
    /// `window` names the surface asking - one Life scroll, one day page - so a screen
    /// replaces its own preheated set without disturbing anybody else's.
    func preheat(_ references: [MediaReference], targetSize: CGSize, window: String) {
        let identifiers = references.map(\.localIdentifier)
        // One update per window at a time, so a screen that scrolled on - or away - can
        // never have an older resolution finish behind the newer one and start caching a
        // window nobody is looking at.
        preheatWork[window]?.cancel()
        preheatWork[window] = Task { @MainActor [weak self] in
            guard let self else { return }
            let issued = self.generation
            let wanted = await self.source.resolve(identifiers)
            guard !Task.isCancelled, issued == self.generation else { return }
            let previous = self.preheated[window]
            if let previous {
                let keep = Set(wanted)
                let dropped = previous.identifiers.filter { !keep.contains($0) }
                if !dropped.isEmpty {
                    self.source.stopCaching(dropped, targetSize: previous.targetSize)
                }
            }
            let held = Set(previous?.identifiers ?? [])
            let added = wanted.filter { !held.contains($0) }
            if !added.isEmpty {
                self.source.startCaching(added, targetSize: targetSize)
            }
            self.preheated[window] = Preheat(identifiers: wanted, targetSize: targetSize)
        }
    }

    func stopPreheating(window: String) {
        preheatWork.removeValue(forKey: window)?.cancel()
        guard let preheat = preheated.removeValue(forKey: window) else { return }
        source.stopCaching(preheat.identifiers, targetSize: preheat.targetSize)
    }

    /// Releases everything that came from the library as it was.
    ///
    /// Photo access is changed outside rmbr, and a narrowed grant covers assets that are
    /// still decoded here. Nothing drawn from the old grant survives the change: pending
    /// requests are cancelled, resolved assets and decoded pixels are dropped, and every
    /// preheated window is handed back to PhotoKit.
    func purge() {
        generation += 1
        for key in Array(inFlight.keys) {
            if let requestID = inFlight[key]?.requestID { source.cancel(requestID) }
            finish(key)
        }
        for work in preheatWork.values { work.cancel() }
        preheatWork.removeAll()
        for window in Array(preheated.keys) { stopPreheating(window: window) }
        images.removeAllObjects()
        source.releaseResolved()
    }

    private func begin(
        token: UUID,
        key: String,
        reference: MediaReference,
        targetSize: CGSize,
        allowNetwork: Bool,
        continuation: AsyncStream<UIImage>.Continuation
    ) async {
        if let cached = images.object(forKey: key as NSString) {
            continuation.yield(cached)
            continuation.finish()
            return
        }

        if let existing = inFlight[key] {
            existing.consumers[token] = continuation
            return
        }

        let request = Request()
        request.consumers[token] = continuation
        inFlight[key] = request

        let resolved = await source.resolve([reference.localIdentifier])
        // Everybody may have scrolled away while the identifier was being resolved.
        guard inFlight[key] === request else { return }
        guard resolved.contains(reference.localIdentifier) else {
            finish(key)
            return
        }

        let requestID = source.requestImage(
            identifier: reference.localIdentifier,
            targetSize: targetSize,
            allowNetwork: allowNetwork
        ) { [weak self] image, isDegraded in
            self?.deliver(image, isDegraded: isDegraded, forKey: key, from: request)
        }
        // A fast delivery can land before the request returns, in which case this request
        // is already finished and the identifier belongs to nothing.
        if inFlight[key] === request { request.requestID = requestID }
    }

    private func deliver(
        _ image: UIImage?,
        isDegraded: Bool,
        forKey key: String,
        from request: Request
    ) {
        // A cancelled request can still deliver late, by which time the key may belong to
        // a request somebody else is waiting on. Only the request that asked may answer.
        guard inFlight[key] === request else { return }
        guard let image else {
            finish(key)
            return
        }
        for continuation in request.consumers.values { continuation.yield(image) }
        guard !isDegraded else { return }
        images.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        finish(key)
    }

    private func finish(_ key: String) {
        guard let request = inFlight.removeValue(forKey: key) else { return }
        for continuation in request.consumers.values { continuation.finish() }
    }

    private func release(token: UUID, key: String) {
        guard let request = inFlight[key] else { return }
        request.consumers.removeValue(forKey: token)
        guard request.consumers.isEmpty else { return }
        inFlight.removeValue(forKey: key)
        if let requestID = request.requestID { source.cancel(requestID) }
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// One capture at one size: what the cache is keyed by, and what a view drawing it
    /// is asking for. Both read this rather than spelling it out, because a view whose
    /// identity is coarser than the key it fetches under keeps whichever size it asked
    /// for first.
    static func key(_ identifier: String, _ size: CGSize) -> String {
        "\(identifier)@\(Int(size.width))x\(Int(size.height))"
    }
}

/// Pixels, and the grant they were fetched under.
///
/// A view holds the only strong reference to what it is drawing, so the generation
/// travels with the image rather than being checked when the fetch is restarted: the
/// store purging is enough to stop these being drawn, in the same main-actor turn.
struct DeliveredImage {
    let image: UIImage
    let generation: Int

    /// The pixels, and nothing at all once the grant they came from has ended.
    func pixels(inGeneration current: Int) -> UIImage? {
        generation == current ? image : nil
    }
}

/// One capture on the page.
struct MediaThumbnail: View {
    @Environment(ThumbnailStore.self) private var store
    @State private var delivered: DeliveredImage?

    let reference: MediaReference
    var targetSize: CGSize = CGSize(width: 600, height: 600)
    var allowNetwork = false
    /// Whether a video says so with a corner badge.
    ///
    /// True everywhere a video would otherwise be indistinguishable from a still. The
    /// full-screen viewer turns it off because it draws a play control of its own in the
    /// middle of the frame and states the length in the caption, and two play triangles
    /// on one frame is one of them saying nothing.
    var showsVideoBadge = true

    var body: some View {
        // The pixels sit in an overlay rather than a stack, so an aspect-fill image can
        // never drive the layout: the frame the caller asked for is the frame this
        // occupies, whatever shape the photograph is.
        Rectangle()
            .fill(Palette.smokedGlass)
            .overlay {
                if let image = store.visibleImage(delivered) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if reference.kind == .video, showsVideoBadge {
                    // A video is never visually indistinguishable from a still, and
                    // never plays without the person asking (RQ-027).
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 16))
                        if let duration = reference.duration {
                            Text(DayFormatting.duration(duration))
                                .font(.utility(11, weight: .medium))
                        }
                    }
                    .foregroundStyle(Palette.moonlightWhite)
                    .shadow(radius: 3)
                    .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if reference.kind == .livePhoto {
                    Image(systemName: "livephoto")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.moonlightWhite)
                        .shadow(radius: 3)
                        .padding(8)
                }
            }
            .clipped()
            // The purge generation is part of the identity, so a purge restarts the fetch
            // against the grant that exists now, and every image is stamped with the
            // generation it was fetched under on the way in. The size is part of it too,
            // because a caller sizing its target from geometry can settle on a different
            // one than it first reported.
            .task(id: "\(store.generation):\(ThumbnailStore.key(reference.localIdentifier, targetSize))") {
                let generation = store.generation
                delivered = store.cachedImage(for: reference, targetSize: targetSize)
                    .map { DeliveredImage(image: $0, generation: generation) }
                for await image in store.deliveries(
                    for: reference,
                    targetSize: targetSize,
                    allowNetwork: allowNetwork
                ) {
                    delivered = DeliveredImage(image: image, generation: generation)
                }
            }
    }
}
