import Foundation
import Photos
import HealthKit
import CoreLocation
import MapKit

// ============================================================================
// EVERY TUNABLE NUMBER IN THE SPIKE LIVES HERE.
// Change one, rebuild, read the MOMENTS section. That is the whole loop.
// ============================================================================
enum MomentHeuristic {

    /// A gap longer than this between two consecutive photos starts a new moment.
    static let maxGapBetweenPhotos: TimeInterval = 45 * 60

    /// Two consecutive photos further apart than this start a new moment even if
    /// they are close in time. Only applied when BOTH carry coordinates.
    static let maxDistanceWithinMoment: CLLocationDistance = 250

    /// Screenshots are almost never "something that happened".
    static let excludeScreenshots = true

    /// A burst counts as one photo, not forty.
    static let collapseBursts = true

    /// Consecutive geotagged photos within this radius are the same place.
    static let placeClusterRadius: CLLocationDistance = 150

    /// Reverse geocoding is rate limited hard. Stop asking after this many lookups per run.
    static let geocodeBudget = 25

    /// Minimum spacing between reverse geocode requests.
    static let geocodeMinimumInterval: TimeInterval = 1.2

    /// Coordinates are rounded to this many decimals for the geocode cache key.
    /// 3 decimals is roughly 110 metres.
    static let geocodeCachePrecision = 3

    /// Sleep for "this date" is looked for between this hour on the previous day...
    static let sleepWindowStartHour = 18

    /// ...and this hour on the date itself.
    static let sleepWindowEndHour = 12
}

// MARK: - Raw material

struct DayAsset {
    let localIdentifier: String
    let date: Date
    let coordinate: CLLocationCoordinate2D?
    let isScreenshot: Bool
    let isVideo: Bool
    let isLive: Bool
    let isFavourite: Bool
    let burstIdentifier: String?
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
    /// How many raw assets this one stands for after burst collapsing.
    var representsFrames: Int = 1

    var flags: String {
        var f: [String] = []
        if isVideo { f.append("video \(Fmt.duration(duration))") }
        if isLive { f.append("live") }
        if isScreenshot { f.append("screenshot") }
        if isFavourite { f.append("fav") }
        if let burstIdentifier {
            f.append("burst \(burstIdentifier.prefix(8))\(representsFrames > 1 ? " x\(representsFrames)" : "")")
        }
        return f.isEmpty ? "-" : f.joined(separator: " ")
    }
}

struct PlaceVisit {
    var start: Date
    var end: Date
    var coordinate: CLLocationCoordinate2D
    var assetCount: Int
    var placeName: String?
}

struct Moment {
    var assets: [DayAsset]
    var splitReason: String
    var coordinate: CLLocationCoordinate2D?
    var placeName: String?
    var representative: DayAsset
    var representativeRule: String

    var start: Date { assets.first?.date ?? .distantPast }
    var end: Date { assets.last?.date ?? .distantPast }
    var frameCount: Int { assets.reduce(0) { $0 + $1.representsFrames } }
}

struct SleepSummary {
    var bedtime: Date?
    var wake: Date?
    var totalAsleep: TimeInterval = 0
    var perStage: [String: TimeInterval] = [:]
    var inBedTotal: TimeInterval = 0
    var sampleCount = 0
    var sources: Set<String> = []
}

struct WorkoutSummary {
    var activity: String
    var start: Date
    var duration: TimeInterval
    var distanceMetres: Double?
    var energyKcal: Double?
    var source: String
}

struct DayResult {
    var date: Date
    var photoAccess: PermissionState = .notDetermined
    var healthAvailable = true
    var rawAssets: [DayAsset] = []
    var workouts: [WorkoutSummary] = []
    var workoutError: String?
    var sleep = SleepSummary()
    var sleepError: String?
    var steps: Double?
    var stepsBySource: [String: Double] = [:]
    var distanceMetres: Double?
    var distanceBySource: [String: Double] = [:]
    var statisticsError: String?
    var places: [PlaceVisit] = []
    var moments: [Moment] = []
    var geocodeNote: String?

    var isEmpty: Bool {
        rawAssets.isEmpty
            && workouts.isEmpty
            && sleep.sampleCount == 0
            && (steps ?? 0) == 0
            && (distanceMetres ?? 0) == 0
    }
}

// MARK: - Reverse geocoding, throttled and cached

final class PlaceNamer {
    private var cache: [String: String?] = [:]
    private var used = 0
    private var lastRequest: Date?
    private(set) var firstError: String?
    private(set) var budgetExhausted = false

    private func key(_ c: CLLocationCoordinate2D) -> String {
        let p = pow(10.0, Double(MomentHeuristic.geocodeCachePrecision))
        return "\((c.latitude * p).rounded() / p),\((c.longitude * p).rounded() / p)"
    }

    func name(for coordinate: CLLocationCoordinate2D) async -> String? {
        let k = key(coordinate)
        if let cached = cache[k] { return cached }

        guard used < MomentHeuristic.geocodeBudget else {
            budgetExhausted = true
            return nil
        }

        if let last = lastRequest {
            let wait = MomentHeuristic.geocodeMinimumInterval - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        lastRequest = Date()
        used += 1

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            if firstError == nil { firstError = "MKReverseGeocodingRequest refused the coordinate" }
            cache[k] = nil
            return nil
        }

        do {
            let items = try await request.mapItems
            let name = items.first.map(Self.describe)
            cache[k] = name
            return name
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
            cache[k] = nil
            return nil
        }
    }

    /// CLGeocoder is deprecated as of iOS 26, so this is MapKit's replacement.
    /// It is still the only network call the spike makes.
    static func describe(_ item: MKMapItem) -> String {
        var parts: [String] = []
        if let name = item.name { parts.append(name) }
        if let city = item.addressRepresentations?.cityWithContext {
            parts.append(city)
        } else if let short = item.address?.shortAddress {
            parts.append(short)
        }

        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "(unnamed place)" : unique.joined(separator: ", ")
    }

    var note: String? {
        var bits: [String] = []
        if budgetExhausted {
            bits.append("geocode budget of \(MomentHeuristic.geocodeBudget) lookups was exhausted; later places show coordinates only")
        }
        if let firstError {
            bits.append("first geocode error: \(firstError)")
        }
        return bits.isEmpty ? nil : bits.joined(separator: "; ")
    }
}

// MARK: - Reconstruction

enum DayReconstruction {

    static func run(date: Date, progress: @escaping @Sendable (String) -> Void) async -> DayResult {
        var result = DayResult(date: date)
        result.photoAccess = Permissions.photoState()

        let start = Fmt.calendar.startOfDay(for: date)
        let end = Fmt.calendar.date(byAdding: .day, value: 1, to: start) ?? start

        // --- Photos ---
        if result.photoAccess == .granted || result.photoAccess == .limited {
            progress("Day: fetching assets…")
            result.rawAssets = fetchAssets(start: start, end: end)
        }

        // --- Health ---
        if HKHealthStore.isHealthDataAvailable() {
            let store = HKHealthStore()

            progress("Day: workouts…")
            do {
                result.workouts = try await fetchWorkouts(store: store, start: start, end: end)
            } catch {
                result.workoutError = error.localizedDescription
            }

            progress("Day: sleep…")
            do {
                result.sleep = try await fetchSleep(store: store, date: start)
            } catch {
                result.sleepError = error.localizedDescription
            }

            progress("Day: steps and distance…")
            do {
                if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
                    let totals = try await cumulativeTotals(store: store, type: steps, unit: .count(), start: start, end: end)
                    result.steps = totals.total
                    result.stepsBySource = totals.bySource
                }
                if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
                    let totals = try await cumulativeTotals(store: store, type: distance, unit: .meter(), start: start, end: end)
                    result.distanceMetres = totals.total
                    result.distanceBySource = totals.bySource
                }
            } catch {
                result.statisticsError = error.localizedDescription
            }
        } else {
            result.healthAvailable = false
        }

        // --- Derived ---
        let namer = PlaceNamer()

        progress("Day: clustering places…")
        result.places = await placeVisits(from: result.rawAssets, namer: namer)

        progress("Day: grouping moments…")
        result.moments = await moments(from: result.rawAssets, namer: namer)

        result.geocodeNote = namer.note
        return result
    }

    // MARK: Photos

    static func fetchAssets(start: Date, end: Date) -> [DayAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            start as NSDate, end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // We want to SEE the bursts so we can collapse them ourselves and print how
        // many frames each one swallowed.
        options.includeAllBurstAssets = true

        let fetched = PHAsset.fetchAssets(with: options)
        var out: [DayAsset] = []
        for index in 0..<fetched.count {
            let asset = fetched.object(at: index)
            guard let created = asset.creationDate else { continue }
            out.append(DayAsset(
                localIdentifier: asset.localIdentifier,
                date: created,
                coordinate: asset.location?.coordinate,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                isVideo: asset.mediaType == .video,
                isLive: asset.mediaSubtypes.contains(.photoLive),
                isFavourite: asset.isFavorite,
                burstIdentifier: asset.burstIdentifier,
                duration: asset.duration,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
        }
        return out
    }

    // MARK: Health

    static func fetchWorkouts(store: HKHealthStore, start: Date, end: Date) async throws -> [WorkoutSummary] {
        let samples = try await HealthSurvey.fetchSamples(
            store: store, type: HKObjectType.workoutType(), start: start, end: end
        )
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                .sumQuantity()?.doubleValue(for: .meter())
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            return WorkoutSummary(
                activity: describeActivity(workout.workoutActivityType),
                start: workout.startDate,
                duration: workout.duration,
                distanceMetres: distance,
                energyKcal: energy,
                source: workout.sourceRevision.source.name
            )
        }
        .sorted { $0.start < $1.start }
    }

    static func fetchSleep(store: HKHealthStore, date: Date) async throws -> SleepSummary {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return SleepSummary()
        }
        let previousDay = Fmt.calendar.date(byAdding: .day, value: -1, to: date) ?? date
        let windowStart = Fmt.calendar.date(
            bySettingHour: MomentHeuristic.sleepWindowStartHour, minute: 0, second: 0, of: previousDay
        ) ?? previousDay
        let windowEnd = Fmt.calendar.date(
            bySettingHour: MomentHeuristic.sleepWindowEndHour, minute: 0, second: 0, of: date
        ) ?? date

        let samples = try await HealthSurvey.fetchSamples(
            store: store, type: type, start: windowStart, end: windowEnd
        )

        var summary = SleepSummary()
        var asleepIntervals: [(Date, Date)] = []

        for sample in samples {
            guard let categorySample = sample as? HKCategorySample else { continue }
            summary.sampleCount += 1
            summary.sources.insert(categorySample.sourceRevision.source.name)
            let stage = describeSleepValue(categorySample.value)
            let length = categorySample.endDate.timeIntervalSince(categorySample.startDate)
            summary.perStage[stage, default: 0] += length

            if isAsleep(categorySample.value) {
                asleepIntervals.append((categorySample.startDate, categorySample.endDate))
                summary.bedtime = min(summary.bedtime ?? categorySample.startDate, categorySample.startDate)
                summary.wake = max(summary.wake ?? categorySample.endDate, categorySample.endDate)
            }
            if categorySample.value == HKCategoryValueSleepAnalysis.inBed.rawValue {
                summary.inBedTotal += length
                summary.bedtime = min(summary.bedtime ?? categorySample.startDate, categorySample.startDate)
            }
        }

        // Merge overlaps so two devices recording the same night do not double count.
        summary.totalAsleep = mergedDuration(asleepIntervals)
        return summary
    }

    static func mergedDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for interval in sorted {
            if var open = current, interval.0 <= open.1 {
                open.1 = max(open.1, interval.1)
                current = open
            } else {
                if let open = current { total += open.1.timeIntervalSince(open.0) }
                current = interval
            }
        }
        if let open = current { total += open.1.timeIntervalSince(open.0) }
        return total
    }

    static func cumulativeTotals(
        store: HKHealthStore,
        type: HKQuantityType,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> (total: Double?, bySource: [String: Double]) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum, .separateBySource]
            ) { _, statistics, error in
                if let error {
                    let nsError = error as NSError
                    // "No data" is an error in HKStatisticsQuery, not an empty result.
                    if nsError.domain == HKError.errorDomain && nsError.code == HKError.errorNoData.rawValue {
                        continuation.resume(returning: (nil, [:]))
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let statistics else {
                    continuation.resume(returning: (nil, [:]))
                    return
                }
                let total = statistics.sumQuantity()?.doubleValue(for: unit)
                var bySource: [String: Double] = [:]
                for source in statistics.sources ?? [] {
                    if let value = statistics.sumQuantity(for: source)?.doubleValue(for: unit) {
                        bySource[source.name, default: 0] += value
                    }
                }
                continuation.resume(returning: (total, bySource))
            }
            store.execute(query)
        }
    }

    // MARK: Places

    static func placeVisits(from assets: [DayAsset], namer: PlaceNamer) async -> [PlaceVisit] {
        let geotagged = assets.compactMap { asset -> (DayAsset, CLLocationCoordinate2D)? in
            guard let coordinate = asset.coordinate else { return nil }
            return (asset, coordinate)
        }
        guard !geotagged.isEmpty else { return [] }

        var visits: [PlaceVisit] = []
        for (asset, coordinate) in geotagged {
            if var open = visits.last,
               distance(open.coordinate, coordinate) <= MomentHeuristic.placeClusterRadius {
                // Roll the centroid forward so a slow drift across a venue stays one place.
                let n = Double(open.assetCount)
                open.coordinate = CLLocationCoordinate2D(
                    latitude: (open.coordinate.latitude * n + coordinate.latitude) / (n + 1),
                    longitude: (open.coordinate.longitude * n + coordinate.longitude) / (n + 1)
                )
                open.assetCount += 1
                open.end = asset.date
                visits[visits.count - 1] = open
            } else {
                visits.append(PlaceVisit(
                    start: asset.date, end: asset.date,
                    coordinate: coordinate, assetCount: 1, placeName: nil
                ))
            }
        }

        for index in visits.indices {
            visits[index].placeName = await namer.name(for: visits[index].coordinate)
        }
        return visits
    }

    // MARK: Moments - the point of the whole spike

    static func moments(from assets: [DayAsset], namer: PlaceNamer) async -> [Moment] {
        var candidates = assets

        if MomentHeuristic.excludeScreenshots {
            candidates = candidates.filter { !$0.isScreenshot }
        }

        if MomentHeuristic.collapseBursts {
            var collapsed: [DayAsset] = []
            var seenBursts: [String: Int] = [:]
            for asset in candidates {
                guard let burst = asset.burstIdentifier else {
                    collapsed.append(asset)
                    continue
                }
                if let index = seenBursts[burst] {
                    collapsed[index].representsFrames += 1
                } else {
                    seenBursts[burst] = collapsed.count
                    collapsed.append(asset)
                }
            }
            candidates = collapsed
        }

        guard !candidates.isEmpty else { return [] }

        var groups: [(assets: [DayAsset], reason: String)] = []
        var current: [DayAsset] = [candidates[0]]
        var currentReason = "first material of the day"
        var lastKnownCoordinate: CLLocationCoordinate2D? = candidates[0].coordinate

        for asset in candidates.dropFirst() {
            let previous = current[current.count - 1]
            let gap = asset.date.timeIntervalSince(previous.date)

            var reason: String?
            if gap > MomentHeuristic.maxGapBetweenPhotos {
                reason = "gap of \(Fmt.duration(gap)) exceeded \(Fmt.duration(MomentHeuristic.maxGapBetweenPhotos))"
            } else if let anchor = lastKnownCoordinate, let next = asset.coordinate {
                let moved = distance(anchor, next)
                if moved > MomentHeuristic.maxDistanceWithinMoment {
                    reason = String(format: "moved %.0fm, exceeding %.0fm", moved, MomentHeuristic.maxDistanceWithinMoment)
                }
            }

            if let reason {
                groups.append((current, currentReason))
                current = [asset]
                currentReason = reason
                lastKnownCoordinate = asset.coordinate
            } else {
                current.append(asset)
                if let coordinate = asset.coordinate { lastKnownCoordinate = coordinate }
            }
        }
        groups.append((current, currentReason))

        var out: [Moment] = []
        for group in groups {
            let coordinates = group.assets.compactMap(\.coordinate)
            let centroid: CLLocationCoordinate2D? = coordinates.isEmpty ? nil : CLLocationCoordinate2D(
                latitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
                longitude: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
            )
            let pick = representative(of: group.assets)
            var moment = Moment(
                assets: group.assets,
                splitReason: group.reason,
                coordinate: centroid,
                placeName: nil,
                representative: pick.asset,
                representativeRule: pick.rule
            )
            if let centroid {
                moment.placeName = await namer.name(for: centroid)
            }
            out.append(moment)
        }
        return out
    }

    /// The representative rule, stated out loud because the whole point is that it
    /// is visible: favourite wins, else the geotagged photo nearest the midpoint,
    /// else whatever is nearest the midpoint.
    static func representative(of assets: [DayAsset]) -> (asset: DayAsset, rule: String) {
        if let favourite = assets.first(where: \.isFavourite) {
            return (favourite, "first favourite in the moment")
        }
        let start = assets.first!.date
        let end = assets.last!.date
        let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)

        let geotagged = assets.filter { $0.coordinate != nil && !$0.isVideo }
        if let pick = nearest(to: midpoint, in: geotagged) {
            return (pick, "geotagged still photo nearest the moment midpoint")
        }
        let stills = assets.filter { !$0.isVideo }
        if let pick = nearest(to: midpoint, in: stills) {
            return (pick, "still photo nearest the moment midpoint (no coordinates available)")
        }
        return (nearest(to: midpoint, in: assets)!, "asset nearest the moment midpoint (video only moment)")
    }

    private static func nearest(to date: Date, in assets: [DayAsset]) -> DayAsset? {
        assets.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // MARK: Labels

    static func describeSleepValue(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: return "in bed"
        case .asleepUnspecified: return "asleep (unspecified)"
        case .awake: return "awake"
        case .asleepCore: return "asleep core"
        case .asleepDeep: return "asleep deep"
        case .asleepREM: return "asleep REM"
        default: return "value \(value)"
        }
    }

    static func isAsleep(_ value: Int) -> Bool {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: return true
        default: return false
        }
    }

    static func describeActivity(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        case .traditionalStrengthTraining: return "Strength training"
        case .functionalStrengthTraining: return "Functional strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stair climbing"
        case .coreTraining: return "Core training"
        case .dance: return "Dance"
        case .mixedCardio: return "Mixed cardio"
        case .tennis: return "Tennis"
        case .soccer: return "Soccer"
        case .basketball: return "Basketball"
        case .golf: return "Golf"
        case .other: return "Other"
        default: return "Activity type \(type.rawValue)"
        }
    }
}
