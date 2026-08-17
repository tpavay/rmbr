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
@MainActor
@Observable
final class ThumbnailStore {
    private let manager = PHCachingImageManager()
    private let images = NSCache<NSString, UIImage>()
    private let assets = NSCache<NSString, PHAsset>()

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
    /// with nothing. A caller that goes away before then ends its own iteration, which
    /// stops any work that has not been handed to PhotoKit yet.
    func deliveries(
        for reference: MediaReference,
        targetSize: CGSize,
        allowNetwork: Bool = false
    ) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let work = Task { @MainActor [weak self] in
                await self?.deliver(
                    reference,
                    targetSize: targetSize,
                    allowNetwork: allowNetwork,
                    to: continuation
                )
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func deliver(
        _ reference: MediaReference,
        targetSize: CGSize,
        allowNetwork: Bool,
        to continuation: AsyncStream<UIImage>.Continuation
    ) async {
        let key = Self.key(reference.localIdentifier, targetSize)
        if let cached = images.object(forKey: key as NSString) {
            continuation.yield(cached)
            continuation.finish()
            return
        }

        guard let asset = await asset(for: reference.localIdentifier), !Task.isCancelled else {
            continuation.finish()
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork

        manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            MainActor.assumeIsolated {
                guard let image else {
                    continuation.finish()
                    return
                }
                continuation.yield(image)
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                self?.images.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                continuation.finish()
            }
        }
    }

    /// Resolves an identifier away from the main actor.
    ///
    /// `fetchAssets` is a Photos database read, and a scroll cannot be made to wait on
    /// one. A lookup that comes back empty is not remembered, so an asset PhotoKit
    /// failed to resolve once is asked for again the next time it appears rather than
    /// being pinned to a placeholder for the rest of the session.
    private func asset(for localIdentifier: String) async -> PHAsset? {
        let key = localIdentifier as NSString
        if let asset = assets.object(forKey: key) { return asset }
        let resolved = await Task.detached(priority: .userInitiated) { () -> PHAsset? in
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            return result.count > 0 ? result.object(at: 0) : nil
        }.value
        guard let resolved else { return nil }
        assets.setObject(resolved, forKey: key)
        return resolved
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
