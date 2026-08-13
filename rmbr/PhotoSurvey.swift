import Foundation
import Photos

struct PhotoYearCounts {
    var total = 0
    var withCoordinates = 0
    var images = 0
    var videos = 0
    var screenshots = 0
    var livePhotos = 0
    var favourites = 0
    var burstMembers = 0
}

struct PhotoSurveyResult {
    var accessState: PermissionState = .notDetermined
    var totalAssets = 0
    var totalIncludingHidden = 0
    var totalIncludingAllBurstAssets = 0
    var oldest: Date?
    var newest: Date?
    var missingCreationDate = 0
    var withCoordinates = 0
    var images = 0
    var videos = 0
    var audio = 0
    var screenshots = 0
    var livePhotos = 0
    var panoramas = 0
    var favourites = 0
    var burstMembers = 0
    var distinctBursts = 0
    var totalVideoDuration: TimeInterval = 0
    var perYear: [Int: PhotoYearCounts] = [:]
}

enum PhotoSurvey {

    /// Default PHFetchOptions exclude hidden assets and collapse bursts down to
    /// their representative photo. We take that as the baseline "library" and
    /// then measure how much the two exclusions are hiding.
    static func run(progress: @escaping @Sendable (String) -> Void) async -> PhotoSurveyResult {
        var result = PhotoSurveyResult()
        result.accessState = Permissions.photoState()

        guard result.accessState == .granted || result.accessState == .limited else {
            return result
        }

        progress("Photos: fetching asset list…")

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        result.totalAssets = assets.count

        var burstIdentifiers = Set<String>()

        progress("Photos: walking \(assets.count) assets…")

        // Deliberately an index loop rather than enumerateObjects: the PhotoKit
        // block is @escaping, which would stop us accumulating into locals.
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            if index % 2_000 == 0 && index > 0 {
                progress("Photos: \(index) / \(assets.count)…")
            }

            var year: Int?
            if let created = asset.creationDate {
                result.oldest = min(result.oldest ?? created, created)
                result.newest = max(result.newest ?? created, created)
                year = Fmt.calendar.component(.year, from: created)
            } else {
                result.missingCreationDate += 1
            }

            var bucket = year.flatMap { result.perYear[$0] } ?? PhotoYearCounts()
            bucket.total += 1

            if asset.location != nil {
                result.withCoordinates += 1
                bucket.withCoordinates += 1
            }

            switch asset.mediaType {
            case .image:
                result.images += 1
                bucket.images += 1
            case .video:
                result.videos += 1
                bucket.videos += 1
                result.totalVideoDuration += asset.duration
            case .audio:
                result.audio += 1
            default:
                break
            }

            if asset.mediaSubtypes.contains(.photoScreenshot) {
                result.screenshots += 1
                bucket.screenshots += 1
            }
            if asset.mediaSubtypes.contains(.photoLive) {
                result.livePhotos += 1
                bucket.livePhotos += 1
            }
            if asset.mediaSubtypes.contains(.photoPanorama) {
                result.panoramas += 1
            }
            if asset.isFavorite {
                result.favourites += 1
                bucket.favourites += 1
            }
            if let burst = asset.burstIdentifier {
                result.burstMembers += 1
                bucket.burstMembers += 1
                burstIdentifiers.insert(burst)
            }

            if let year { result.perYear[year] = bucket }
        }

        result.distinctBursts = burstIdentifiers.count

        // Two counting variants, measured rather than assumed.
        progress("Photos: counting hidden assets…")
        let hiddenOptions = PHFetchOptions()
        hiddenOptions.includeHiddenAssets = true
        result.totalIncludingHidden = PHAsset.fetchAssets(with: hiddenOptions).count

        progress("Photos: counting expanded bursts…")
        let burstOptions = PHFetchOptions()
        burstOptions.includeAllBurstAssets = true
        result.totalIncludingAllBurstAssets = PHAsset.fetchAssets(with: burstOptions).count

        return result
    }

    static func report(_ r: PhotoSurveyResult) -> String {
        var out = Fmt.rule("photos") + "\n\n"

        out += "Access: \(r.accessState.rawValue)\n"
        guard r.accessState == .granted || r.accessState == .limited else {
            out += "\nNo photo library access, so nothing here could be reached.\n"
            out += "Every number below would have been the whole answer to 'how much past is there'.\n"
            return out
        }
        if r.accessState == .limited {
            out += "WARNING: limited selection. Every number below describes only the assets\n"
            out += "the captain hand-picked, NOT the library. Re-grant as full access to get a\n"
            out += "meaningful survey.\n"
        }
        out += "\n"

        out += "Total assets (default fetch)      : \(Fmt.num(r.totalAssets))\n"
        out += "  ... including hidden            : \(Fmt.num(r.totalIncludingHidden)) (\(r.totalIncludingHidden - r.totalAssets) hidden)\n"
        out += "  ... including all burst frames  : \(Fmt.num(r.totalIncludingAllBurstAssets)) (\(r.totalIncludingAllBurstAssets - r.totalAssets) non-representative burst frames)\n"
        out += "Oldest asset creationDate         : \(Fmt.stamp(r.oldest))\n"
        out += "Newest asset creationDate         : \(Fmt.stamp(r.newest))\n"
        if let oldest = r.oldest, let newest = r.newest {
            let days = Fmt.calendar.dateComponents([.day], from: oldest, to: newest).day ?? 0
            out += "Span                              : \(days) days\n"
        }
        out += "Assets with NO creationDate       : \(Fmt.num(r.missingCreationDate))\n"
        out += "\n"

        out += "With GPS coordinates              : \(Fmt.num(r.withCoordinates)) (\(Fmt.pct(r.withCoordinates, of: r.totalAssets)) of all assets)\n"
        out += "Photos                            : \(Fmt.num(r.images))\n"
        out += "Videos                            : \(Fmt.num(r.videos)), total \(Fmt.duration(r.totalVideoDuration))\n"
        out += "Audio                             : \(Fmt.num(r.audio))\n"
        out += "Screenshots                       : \(Fmt.num(r.screenshots)) (\(Fmt.pct(r.screenshots, of: r.totalAssets)))\n"
        out += "Live Photos                       : \(Fmt.num(r.livePhotos))\n"
        out += "Panoramas                         : \(Fmt.num(r.panoramas))\n"
        out += "Favourites                        : \(Fmt.num(r.favourites))\n"
        out += "Assets belonging to a burst       : \(Fmt.num(r.burstMembers)) across \(Fmt.num(r.distinctBursts)) distinct bursts\n"
        out += "\n"

        out += "PER YEAR\n"
        out += "(GPS% is the share of that year's assets carrying coordinates. For rebuilt past\n"
        out += " days, that column is the ONLY source of place - see the LOCATION section.)\n\n"
        out += "YEAR      TOTAL      GPS   GPS%   PHOTOS   VIDEOS    SHOTS     LIVE      FAV    BURST\n"
        out += "----  ---------  -------  -----  -------  -------  -------  -------  -------  -------\n"

        if r.perYear.isEmpty {
            out += "(no assets carried a creation date, so no year breakdown is possible)\n"
        }
        for year in r.perYear.keys.sorted() {
            let y = r.perYear[year]!
            out += Fmt.pad("\(year)", 6)
            out += Fmt.num(y.total, 9) + "  "
            out += Fmt.num(y.withCoordinates, 7) + "  "
            out += Fmt.pct(y.withCoordinates, of: y.total, width: 5) + "  "
            out += Fmt.num(y.images, 7) + "  "
            out += Fmt.num(y.videos, 7) + "  "
            out += Fmt.num(y.screenshots, 7) + "  "
            out += Fmt.num(y.livePhotos, 7) + "  "
            out += Fmt.num(y.favourites, 7) + "  "
            out += Fmt.num(y.burstMembers, 7) + "\n"
        }

        out += "\nNOTES\n"
        out += "- Default fetch covers the user's own library only. Shared-album and iTunes-synced\n"
        out += "  assets are excluded by PhotoKit unless explicitly opted in; they are not counted.\n"
        out += "- creationDate is whatever the file claims. It is device local time with no\n"
        out += "  timezone attached, so a photo taken abroad reads back in the phone's current zone.\n"

        return out
    }
}
