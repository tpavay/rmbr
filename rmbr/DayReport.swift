import Foundation
import CoreLocation

/// Renders a reconstructed day as the monospaced page the captain reads on a phone.
enum DayReport {

    static func render(_ r: DayResult) -> String {
        var out = Fmt.rule("day \(Fmt.date(r.date))") + "\n\n"

        if r.isEmpty {
            out += "NOTHING KNOWN ABOUT THIS DAY.\n\n"
            out += "No photos or videos, no workouts, no sleep samples, no steps, no distance.\n"
            out += "Either nothing was recorded, or the sources were not readable:\n"
            out += "  Photo access   : \(r.photoAccess.rawValue)\n"
            out += "  HealthKit      : \(r.healthAvailable ? "available (read grants are never reported)" : "UNAVAILABLE on this device")\n"
            out += "\nThis is the state a rebuilt day falls into when the raw material is absent,\n"
            out += "and the product has to have an answer for it.\n"
            return out
        }

        out += timeline(r)
        out += workouts(r)
        out += sleep(r)
        out += activity(r)
        out += places(r)
        out += moments(r)
        out += heuristicFooter(r)
        return out
    }

    // MARK: Sections

    private static func timeline(_ r: DayResult) -> String {
        var out = "--- PHOTOS & VIDEOS (\(r.rawAssets.count)) ---\n\n"

        guard r.photoAccess == .granted || r.photoAccess == .limited else {
            return out + "Photo access is \(r.photoAccess.rawValue). Nothing could be read.\n\n"
        }
        guard !r.rawAssets.isEmpty else {
            return out + "None on this day.\n\n"
        }
        if r.photoAccess == .limited {
            out += "NOTE: limited photo selection - this is only what was hand-picked.\n\n"
        }

        out += "TIME      GPS  PLACE                              FLAGS\n"
        out += "--------  ---  ---------------------------------  ------------------------\n"

        let placeLookup = r.places
        for asset in r.rawAssets {
            out += Fmt.pad(Fmt.time(asset.date), 10)
            out += Fmt.pad(asset.coordinate == nil ? "no" : "yes", 5)
            var place = "-"
            if let coordinate = asset.coordinate {
                if let match = placeLookup.first(where: {
                    DayReconstruction.distance($0.coordinate, coordinate) <= MomentHeuristic.placeClusterRadius
                }), let name = match.placeName {
                    place = name
                } else {
                    place = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
                }
            }
            out += Fmt.pad(String(place.prefix(33)), 35)
            out += asset.flags
            out += "\n"
        }
        out += "\n"
        return out
    }

    private static func workouts(_ r: DayResult) -> String {
        var out = "--- WORKOUTS (\(r.workouts.count)) ---\n\n"
        if let error = r.workoutError {
            return out + "QUERY ERROR: \(error)\n\n"
        }
        guard !r.workouts.isEmpty else {
            return out + "None on this day (or workout reads were refused - HealthKit does not say which).\n\n"
        }
        for workout in r.workouts {
            out += "\(Fmt.time(workout.start))  \(workout.activity)\n"
            out += "          duration \(Fmt.duration(workout.duration))"
            if let distance = workout.distanceMetres {
                out += String(format: "  distance %.2f km", distance / 1000)
            }
            if let energy = workout.energyKcal {
                out += String(format: "  energy %.0f kcal", energy)
            }
            out += "\n          source: \(workout.source)\n"
        }
        out += "\n"
        return out
    }

    private static func sleep(_ r: DayResult) -> String {
        var out = "--- SLEEP ---\n\n"
        out += "Window searched: \(MomentHeuristic.sleepWindowStartHour):00 the previous day to \(MomentHeuristic.sleepWindowEndHour):00 on this day.\n\n"

        if let error = r.sleepError {
            return out + "QUERY ERROR: \(error)\n\n"
        }
        guard r.sleep.sampleCount > 0 else {
            return out + "No sleep samples in that window (or sleep reads were refused).\n\n"
        }

        out += "Bedtime      : \(Fmt.stamp(r.sleep.bedtime))\n"
        out += "Wake         : \(Fmt.stamp(r.sleep.wake))\n"
        out += "Total asleep : \(Fmt.duration(r.sleep.totalAsleep))  (overlapping samples merged, not summed)\n"
        if r.sleep.inBedTotal > 0 {
            out += "In bed total : \(Fmt.duration(r.sleep.inBedTotal))\n"
        }
        out += "Samples      : \(r.sleep.sampleCount) from \(r.sleep.sources.sorted().joined(separator: ", "))\n"
        if r.sleep.sources.count > 1 {
            out += "NOTE: more than one source recorded this night. They will disagree.\n"
        }
        if !r.sleep.perStage.isEmpty {
            out += "\nBY STAGE (raw sums, may double count across sources)\n"
            for stage in r.sleep.perStage.keys.sorted() {
                out += "  \(Fmt.pad(stage, 22))\(Fmt.duration(r.sleep.perStage[stage]))\n"
            }
        }
        out += "\n"
        return out
    }

    private static func activity(_ r: DayResult) -> String {
        var out = "--- STEPS & DISTANCE ---\n\n"
        if let error = r.statisticsError {
            out += "QUERY ERROR: \(error)\n\n"
            return out
        }

        if let steps = r.steps {
            out += "Steps    : \(Fmt.num(Int(steps.rounded())))\n"
            for source in r.stepsBySource.keys.sorted() {
                out += "           \(Fmt.pad(source, 26)) \(Fmt.num(Int((r.stepsBySource[source] ?? 0).rounded())))\n"
            }
        } else {
            out += "Steps    : no data (or refused)\n"
        }

        if let distance = r.distanceMetres {
            out += String(format: "Distance : %.2f km\n", distance / 1000)
            for source in r.distanceBySource.keys.sorted() {
                out += String(format: "           %@ %.2f km\n", Fmt.pad(source, 26), (r.distanceBySource[source] ?? 0) / 1000)
            }
        } else {
            out += "Distance : no data (or refused)\n"
        }

        if r.stepsBySource.count > 1 || r.distanceBySource.count > 1 {
            out += "\nNOTE: multiple sources. The headline figure is HealthKit's merged total; the\n"
            out += "per-source lines below it will add up to more than the headline.\n"
        }
        out += "\n"
        return out
    }

    private static func places(_ r: DayResult) -> String {
        var out = "--- PLACES IN TIME ORDER (\(r.places.count)) ---\n\n"
        out += "Derived from photo coordinates only, collapsed at \(Int(MomentHeuristic.placeClusterRadius))m.\n\n"

        guard !r.places.isEmpty else {
            return out + "No geotagged photos on this day, so the day has no known places at all.\n\n"
        }
        for place in r.places {
            let window = place.start == place.end
                ? Fmt.time(place.start)
                : "\(Fmt.time(place.start))-\(Fmt.time(place.end))"
            out += Fmt.pad(window, 20)
            out += place.placeName ?? String(format: "%.4f, %.4f", place.coordinate.latitude, place.coordinate.longitude)
            out += "  (\(place.assetCount) photo\(place.assetCount == 1 ? "" : "s"))\n"
        }
        out += "\n"
        return out
    }

    private static func moments(_ r: DayResult) -> String {
        var out = "--- PROPOSED MOMENTS (\(r.moments.count)) ---\n\n"
        out += "Not tuned. This is what the heuristic below actually produced.\n\n"

        guard !r.moments.isEmpty else {
            out += "No moments. Nothing survived the filters: either the day had no photos, or\n"
            out += "every photo on it was a screenshot.\n\n"
            return out
        }

        for (index, moment) in r.moments.enumerated() {
            let window = moment.start == moment.end
                ? Fmt.time(moment.start)
                : "\(Fmt.time(moment.start)) - \(Fmt.time(moment.end))"
            out += "MOMENT \(index + 1)  \(window)  (\(Fmt.duration(moment.end.timeIntervalSince(moment.start))))\n"
            out += "  place      : "
            if let name = moment.placeName {
                out += name + "\n"
            } else if let coordinate = moment.coordinate {
                out += String(format: "%.4f, %.4f (not geocoded)\n", coordinate.latitude, coordinate.longitude)
            } else {
                out += "UNKNOWN - no photo in this moment carried coordinates\n"
            }
            out += "  photos     : \(moment.assets.count) assets, \(moment.frameCount) frames once bursts are counted\n"
            out += "  starts here: \(moment.splitReason)\n"
            out += "  represent. : \(Fmt.time(moment.representative.date))  \(moment.representative.flags)\n"
            out += "               \(moment.representative.localIdentifier)\n"
            out += "               rule: \(moment.representativeRule)\n"
            out += "\n"
        }
        return out
    }

    private static func heuristicFooter(_ r: DayResult) -> String {
        var out = "--- HEURISTIC IN FORCE ---\n\n"
        out += "  maxGapBetweenPhotos     \(Fmt.duration(MomentHeuristic.maxGapBetweenPhotos))\n"
        out += "  maxDistanceWithinMoment \(Int(MomentHeuristic.maxDistanceWithinMoment))m\n"
        out += "  placeClusterRadius      \(Int(MomentHeuristic.placeClusterRadius))m\n"
        out += "  excludeScreenshots      \(MomentHeuristic.excludeScreenshots)\n"
        out += "  collapseBursts          \(MomentHeuristic.collapseBursts)\n"
        out += "  geocodeBudget           \(MomentHeuristic.geocodeBudget) lookups per run\n"
        out += "\nAll of these are constants at the top of DayReconstruction.swift.\n"
        if let note = r.geocodeNote {
            out += "\nGEOCODER: \(note)\n"
        }
        return out
    }
}
