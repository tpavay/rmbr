import Foundation
import Photos

/// What one whole-library metadata pass cost.
///
/// Reported rather than estimated. The first run on a large library is the number that
/// decides whether the product's promise is deliverable, so it is measured on the real
/// device and printed, not extrapolated (`docs/phase-0-findings.md` measured the shape
/// of the library; this measures the shape of the work).
struct IndexRunMetrics: Sendable, Codable, Hashable {
    var assetCount: Int = 0
    var recordCount: Int = 0
    var skippedWithoutCreationDate: Int = 0
    var geotaggedCount: Int = 0
    var screenshotCount: Int = 0
    /// Seconds spent inside `PHAsset.fetchAssets`.
    var fetchSeconds: Double = 0
    /// Seconds spent walking asset properties.
    var walkSeconds: Double = 0
    /// Seconds spent writing the snapshot to disk.
    var persistSeconds: Double = 0
    var totalSeconds: Double { fetchSeconds + walkSeconds + persistSeconds }

    var assetsPerSecond: Double {
        walkSeconds > 0 ? Double(assetCount) / walkSeconds : 0
    }
}

/// A cheap fingerprint of the library, used to spot a stale cached index.
struct LibrarySignature: Sendable, Codable, Hashable {
    let assetCount: Int
    let newestCreationDate: Date?
    /// Which assets a limited grant actually covers.
    ///
    /// Swapping one chosen photograph for another leaves the count and the newest date
    /// untouched, so under limited access those two numbers cannot tell that the grant
    /// now covers a different set. A hash of the chosen identifiers can, and a limited
    /// selection is small enough to hash. Nil under full access, where the coarse
    /// signature already describes the whole library.
    var selectionFingerprint: String?
}

/// The whole-library metadata index, and the pass that builds it.
///
/// Metadata first, always. This pass never requests pixels, never downloads an
/// iCloud-only original and never calls the network, so a library whose originals live
/// in iCloud indexes at the same speed as one that is entirely local (RQ-063). Days
/// become readable from this index alone; enrichment arrives later on its own schedule.
struct PhotoLibraryIndexer: Sendable {
    /// Reported as assets are walked, so the first run can show a real counter rather
    /// than a spinner.
    typealias ProgressHandler = @Sendable (Int, Int) -> Void

    let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    struct Output: Sendable {
        let records: [CaptureRecord]
        let metrics: IndexRunMetrics
    }

    /// Walks every accessible asset once.
    ///
    /// Shared-album and iTunes-synced assets are deliberately excluded: PhotoKit cannot
    /// establish that the owner took an imported asset or was present at its
    /// coordinate, so admitting them would let another person's photograph put the
    /// captain somewhere he never was (RQ-008).
    func buildIndex(progress: ProgressHandler? = nil) throws -> Output {
        var metrics = IndexRunMetrics()

        let fetchStart = Date()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        let assets = PHAsset.fetchAssets(with: options)
        metrics.fetchSeconds = Date().timeIntervalSince(fetchStart)
        metrics.assetCount = assets.count

        let walkStart = Date()
        var records: [CaptureRecord] = []
        records.reserveCapacity(assets.count)

        for index in 0..<assets.count {
            if index % 512 == 0 {
                try Task.checkCancellation()
                progress?(index, assets.count)
            }
            let asset = assets.object(at: index)
            guard let record = Self.record(from: asset, timeZone: timeZone) else {
                metrics.skippedWithoutCreationDate += 1
                continue
            }
            if record.coordinate != nil { metrics.geotaggedCount += 1 }
            if record.isScreenshot || record.isScreenRecording { metrics.screenshotCount += 1 }
            records.append(record)
        }
        metrics.walkSeconds = Date().timeIntervalSince(walkStart)
        metrics.recordCount = records.count
        progress?(assets.count, assets.count)

        return Output(records: records, metrics: metrics)
    }

    /// A cheap check for whether the library has changed since a snapshot was built.
    ///
    /// Two bounded fetches rather than a full walk, so a warm launch can decide in
    /// milliseconds whether the cached index still describes the library. It catches
    /// additions, deletions and a changed newest capture; it deliberately does not
    /// catch an edit to an old asset, which the change-observer path this leaves room
    /// for will handle.
    static func librarySignature(coversWholeLibrary: Bool = true) -> LibrarySignature {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        let all = PHAsset.fetchAssets(with: options)

        let newestOptions = PHFetchOptions()
        newestOptions.includeAssetSourceTypes = [.typeUserLibrary]
        newestOptions.includeHiddenAssets = false
        newestOptions.includeAllBurstAssets = false
        newestOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        newestOptions.fetchLimit = 1
        let newest = PHAsset.fetchAssets(with: newestOptions)

        var selectionFingerprint: String?
        if !coversWholeLibrary {
            var identifiers: [String] = []
            identifiers.reserveCapacity(all.count)
            all.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
            selectionFingerprint = StableHash.hex(of: identifiers.sorted())
        }

        return LibrarySignature(
            assetCount: all.count,
            newestCreationDate: newest.count > 0 ? newest.object(at: 0).creationDate : nil,
            selectionFingerprint: selectionFingerprint
        )
    }

    static func record(from asset: PHAsset, timeZone: TimeZone) -> CaptureRecord? {
        // An asset with no creation date cannot be placed on a day. It is counted and
        // left out rather than guessed onto the date it was imported.
        guard let creationDate = asset.creationDate else { return nil }

        let subtypes = asset.mediaSubtypes
        let isScreenshot = subtypes.contains(.photoScreenshot)
        let isScreenRecording = subtypes.contains(.videoScreenRecording)
        let isLive = subtypes.contains(.photoLive)

        let kind: MediaKind
        switch asset.mediaType {
        case .video: kind = .video
        case .image: kind = isLive ? .livePhoto : .photo
        default: return nil
        }

        let location = asset.location
        let coordinate = location.map {
            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        let accuracy = location.flatMap { $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil }

        return CaptureRecord(
            id: MediaID(asset.localIdentifier),
            localIdentifier: asset.localIdentifier,
            kind: kind,
            captureTime: .floatingLocal(from: creationDate, readIn: timeZone),
            instant: creationDate,
            duration: asset.mediaType == .video ? asset.duration : nil,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            hasAdjustments: asset.hasAdjustments,
            isScreenshot: isScreenshot,
            isScreenRecording: isScreenRecording,
            isHidden: asset.isHidden,
            burstIdentifier: asset.burstIdentifier,
            // The default fetch already returns only representative burst frames, so an
            // asset that reaches here and belongs to a burst is that burst's stand-in.
            isRepresentativeBurstFrame: true,
            // How many frames the burst actually held is not knowable from this fetch,
            // and "forty photographs in eight seconds" is itself a fact about a moment.
            // It is left at zero rather than reported as one, because a wrong count is
            // worse than a missing one; establishing it needs a second fetch with
            // `includeAllBurstAssets`.
            representedBurstFrames: 0,
            coordinate: coordinate,
            horizontalAccuracyMetres: accuracy
        )
    }
}
