import Photos
import SwiftUI
import UIKit

/// Delivers pixels for a media reference.
///
/// rmbr keeps no copies of anybody's photographs. Every image on screen comes from
/// PhotoKit's own cache through `PHCachingImageManager`, which is also why an
/// iCloud-only original does not stall a scroll: network access is off for inline
/// thumbnails and only turned on for a capture the person opened.
@MainActor
@Observable
final class ThumbnailStore {
    private let manager = PHCachingImageManager()
    private var images: [String: UIImage] = [:]
    private var requested: Set<String> = []
    private var assets: [String: PHAsset] = [:]

    func image(for reference: MediaReference, targetSize: CGSize) -> UIImage? {
        let key = Self.key(reference.localIdentifier, targetSize)
        if let image = images[key] { return image }
        request(reference, targetSize: targetSize)
        return nil
    }

    func request(_ reference: MediaReference, targetSize: CGSize, allowNetwork: Bool = false) {
        let key = Self.key(reference.localIdentifier, targetSize)
        guard !requested.contains(key) else { return }
        requested.insert(key)

        guard let asset = asset(for: reference.localIdentifier) else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork

        manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let image else { return }
            MainActor.assumeIsolated {
                self?.images[key] = image
            }
        }
    }

    private func asset(for localIdentifier: String) -> PHAsset? {
        if let asset = assets[localIdentifier] { return asset }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard result.count > 0 else { return nil }
        let asset = result.object(at: 0)
        assets[localIdentifier] = asset
        return asset
    }

    private static func key(_ identifier: String, _ size: CGSize) -> String {
        "\(identifier)@\(Int(size.width))x\(Int(size.height))"
    }
}

/// One capture on the page.
struct MediaThumbnail: View {
    @Environment(ThumbnailStore.self) private var store

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
                if let image = store.image(for: reference, targetSize: targetSize) {
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
            .task {
                store.request(reference, targetSize: targetSize, allowNetwork: allowNetwork)
            }
    }
}
