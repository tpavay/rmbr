import Photos
import SwiftUI
import UIKit

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
    private let manager = PHCachingImageManager()
    private let images = NSCache<NSString, UIImage>()
    private let assets = NSCache<NSString, PHAsset>()
    private var inFlight: [String: Request] = [:]
    private var preheated: [String: Preheat] = [:]
    private var preheatWork: [String: Task<Void, Never>] = [:]

    /// One PhotoKit request and everybody waiting on it.
    @MainActor
    private final class Request {
        var requestID: PHImageRequestID?
        var consumers: [UUID: AsyncStream<UIImage>.Continuation] = [:]
    }

    private struct Preheat {
        let assets: [PHAsset]
        let targetSize: CGSize
    }

    init() {
        images.totalCostLimit = 48 * 1024 * 1024
        images.countLimit = 200
        assets.countLimit = 1_000
    }

    /// What is already decoded at this size, if anything.
    func cachedImage(for reference: MediaReference, targetSize: CGSize) -> UIImage? {
        images.object(forKey: Self.key(reference.localIdentifier, targetSize) as NSString)
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
            let wanted = await self.assets(for: identifiers)
            guard !Task.isCancelled else { return }
            let previous = self.preheated[window]
            if let previous {
                let keep = Set(wanted.map(\.localIdentifier))
                let dropped = previous.assets.filter { !keep.contains($0.localIdentifier) }
                if !dropped.isEmpty {
                    self.manager.stopCachingImages(
                        for: dropped,
                        targetSize: previous.targetSize,
                        contentMode: .aspectFill,
                        options: nil
                    )
                }
            }
            let held = Set(previous?.assets.map(\.localIdentifier) ?? [])
            let added = wanted.filter { !held.contains($0.localIdentifier) }
            if !added.isEmpty {
                self.manager.startCachingImages(
                    for: added,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: nil
                )
            }
            self.preheated[window] = Preheat(assets: wanted, targetSize: targetSize)
        }
    }

    func stopPreheating(window: String) {
        preheatWork.removeValue(forKey: window)?.cancel()
        guard let preheat = preheated.removeValue(forKey: window) else { return }
        manager.stopCachingImages(
            for: preheat.assets,
            targetSize: preheat.targetSize,
            contentMode: .aspectFill,
            options: nil
        )
    }

    /// Releases everything that came from the library as it was.
    ///
    /// Photo access is changed outside rmbr, and a narrowed grant covers assets that are
    /// still decoded here. Nothing drawn from the old grant survives the change: pending
    /// requests are cancelled, resolved assets and decoded pixels are dropped, and every
    /// preheated window is handed back to PhotoKit.
    func purge() {
        for key in Array(inFlight.keys) {
            if let requestID = inFlight[key]?.requestID { manager.cancelImageRequest(requestID) }
            finish(key)
        }
        for work in preheatWork.values { work.cancel() }
        preheatWork.removeAll()
        for window in Array(preheated.keys) { stopPreheating(window: window) }
        images.removeAllObjects()
        assets.removeAllObjects()
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

        let asset = await asset(for: reference.localIdentifier)
        // Everybody may have scrolled away while the identifier was being resolved.
        guard inFlight[key] === request else { return }
        guard let asset else {
            finish(key)
            return
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
        ) { [weak self] image, info in
            MainActor.assumeIsolated {
                self?.deliver(image, info: info, forKey: key, from: request)
            }
        }
        // A fast delivery can land before `requestImage` returns, in which case this
        // request is already finished and the identifier belongs to nothing.
        if inFlight[key] === request { request.requestID = requestID }
    }

    private func deliver(
        _ image: UIImage?,
        info: [AnyHashable: Any]?,
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
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
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
        if let requestID = request.requestID { manager.cancelImageRequest(requestID) }
    }

    /// Resolves an identifier away from the main actor.
    ///
    /// `fetchAssets` is a Photos database read, and a scroll cannot be made to wait on
    /// one. A lookup that comes back empty is not remembered, so an asset PhotoKit
    /// failed to resolve once is asked for again the next time it appears rather than
    /// being pinned to a placeholder for the rest of the session.
    private func asset(for localIdentifier: String) async -> PHAsset? {
        if let asset = assets.object(forKey: localIdentifier as NSString) { return asset }
        return await self.assets(for: [localIdentifier]).first
    }

    private func assets(for localIdentifiers: [String]) async -> [PHAsset] {
        var resolved: [String: PHAsset] = [:]
        var missing: [String] = []
        for identifier in localIdentifiers {
            if let asset = assets.object(forKey: identifier as NSString) {
                resolved[identifier] = asset
            } else if !missing.contains(identifier) {
                missing.append(identifier)
            }
        }

        if !missing.isEmpty {
            let fetched = await Task.detached(priority: .userInitiated) { () -> [PHAsset] in
                let result = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
                var assets: [PHAsset] = []
                result.enumerateObjects { asset, _, _ in assets.append(asset) }
                return assets
            }.value
            for asset in fetched {
                assets.setObject(asset, forKey: asset.localIdentifier as NSString)
                resolved[asset.localIdentifier] = asset
            }
        }

        return localIdentifiers.compactMap { resolved[$0] }
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private static func key(_ identifier: String, _ size: CGSize) -> String {
        "\(identifier)@\(Int(size.width))x\(Int(size.height))"
    }
}

/// One capture on the page.
struct MediaThumbnail: View {
    @Environment(ThumbnailStore.self) private var store
    @State private var image: UIImage?

    let reference: MediaReference
    var targetSize: CGSize = CGSize(width: 600, height: 600)
    var allowNetwork = false

    var body: some View {
        // The pixels sit in an overlay rather than a stack, so an aspect-fill image can
        // never drive the layout: the frame the caller asked for is the frame this
        // occupies, whatever shape the photograph is.
        Rectangle()
            .fill(Palette.smokedGlass)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if reference.kind == .video {
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
            .task(id: reference.localIdentifier) {
                image = store.cachedImage(for: reference, targetSize: targetSize)
                for await delivered in store.deliveries(
                    for: reference,
                    targetSize: targetSize,
                    allowNetwork: allowNetwork
                ) {
                    image = delivered
                }
            }
    }
}
