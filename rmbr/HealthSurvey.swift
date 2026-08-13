import Foundation
import HealthKit

/// One health type's answer to "how much past is there".
struct HealthTypeSurvey {
    var label: String
    var oldest: Date?
    var newest: Date?
    var totalSamples = 0
    var perYearSamples: [Int: Int] = [:]
    /// Summed value per year for cumulative quantity types (steps, metres). nil for
    /// types where a sum is meaningless (sleep, workouts).
    var perYearSum: [Int: Double] = [:]
    var sumUnitLabel: String?
    var sourceNames: Set<String> = []
    var error: String?
}

struct HealthSurveyResult {
    var available = true
    var state: PermissionState = .notDetermined
    var note = ""
    var types: [HealthTypeSurvey] = []
}

enum HealthSurvey {

    /// Sample counting is done month by month. HealthKit has no count-only query,
    /// so the only way to know how many samples exist is to fetch them; monthly
    /// buckets keep peak memory to one month of step samples rather than ten years.
    static func run(
        state: PermissionState,
        note: String,
        progress: @escaping @Sendable (String) -> Void
    ) async -> HealthSurveyResult {

        var result = HealthSurveyResult()
        result.state = state
        result.note = note

        guard HKHealthStore.isHealthDataAvailable() else {
            result.available = false
            return result
        }

        let store = HKHealthStore()

        var jobs: [(String, HKSampleType, HKUnit?, String?)] = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            jobs.append(("Sleep analysis", sleep, nil, nil))
        }
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
            jobs.append(("Step count", steps, HKUnit.count(), "steps"))
        }
        if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            jobs.append(("Distance walking/running", distance, HKUnit.meter(), "m"))
        }
        jobs.append(("Workouts", HKObjectType.workoutType(), nil, nil))

        for (label, type, unit, unitLabel) in jobs {
            progress("Health: \(label) - finding oldest sample…")
            var survey = HealthTypeSurvey(label: label)
            survey.sumUnitLabel = unitLabel

            do {
                survey.oldest = try await extremeSampleDate(store: store, type: type, ascending: true)
                survey.newest = try await extremeSampleDate(store: store, type: type, ascending: false)
            } catch {
                survey.error = error.localizedDescription
                result.types.append(survey)
                continue
            }

            guard let oldest = survey.oldest else {
                result.types.append(survey)
                continue
            }

            let now = Date()
            var cursor = Fmt.calendar.dateInterval(of: .month, for: oldest)?.start ?? oldest

            while cursor < now {
                let next = Fmt.calendar.date(byAdding: .month, value: 1, to: cursor) ?? now
                let year = Fmt.calendar.component(.year, from: cursor)
                progress("Health: \(label) - \(Fmt.date(cursor))…")

                do {
                    let samples = try await fetchSamples(
                        store: store,
                        type: type,
                        start: cursor,
                        end: min(next, now)
                    )
                    if !samples.isEmpty {
                        survey.totalSamples += samples.count
                        survey.perYearSamples[year, default: 0] += samples.count
                        for sample in samples {
                            survey.sourceNames.insert(sample.sourceRevision.source.name)
                            if let unit, let quantitySample = sample as? HKQuantitySample {
                                survey.perYearSum[year, default: 0] += quantitySample.quantity.doubleValue(for: unit)
                            }
                        }
                    }
                } catch {
                    if survey.error == nil {
                        survey.error = "\(Fmt.date(cursor)): \(error.localizedDescription)"
                    }
                }

                cursor = next
            }

            result.types.append(survey)
        }

        return result
    }

    // MARK: Queries

    static func extremeSampleDate(
        store: HKHealthStore,
        type: HKSampleType,
        ascending: Bool
    ) async throws -> Date? {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples?.first?.startDate)
                }
            }
            store.execute(query)
        }
    }

    static func fetchSamples(
        store: HKHealthStore,
        type: HKSampleType,
        start: Date,
        end: Date
    ) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    // MARK: Report

    static func report(_ r: HealthSurveyResult) -> String {
        var out = Fmt.rule("health") + "\n\n"

        guard r.available else {
            out += "HealthKit is UNAVAILABLE on this device (isHealthDataAvailable() == false).\n"
            out += "Nothing health-shaped could be reached at all.\n"
            return out
        }

        out += "Authorisation: \(r.state.rawValue)\n"
        if !r.note.isEmpty {
            out += "\(r.note)\n"
        }
        out += "\nHealthKit never reports read permission. An empty type below means either\n"
        out += "'the captain said no to this type' or 'there is no such data'. The two are\n"
        out += "indistinguishable from inside the app, by design.\n\n"

        for type in r.types {
            out += "--- \(type.label) ---\n"

            if let error = type.error {
                out += "  QUERY ERROR: \(error)\n\n"
                if type.totalSamples == 0 { continue }
            }

            guard type.oldest != nil else {
                out += "  NOTHING REACHABLE. Zero samples returned across all of time.\n\n"
                continue
            }

            out += "  Oldest sample : \(Fmt.stamp(type.oldest))\n"
            out += "  Newest sample : \(Fmt.stamp(type.newest))\n"
            out += "  Total samples : \(Fmt.num(type.totalSamples))\n"
            let sources = type.sourceNames.sorted().joined(separator: ", ")
            out += "  Sources       : \(sources.isEmpty ? "-" : sources)\n"

            if type.perYearSamples.isEmpty {
                out += "  No samples fell inside any month bucket.\n\n"
                continue
            }

            out += "\n  YEAR      SAMPLES"
            if let unitLabel = type.sumUnitLabel {
                out += "        TOTAL (\(unitLabel))"
            }
            out += "\n  ----  -----------"
            if type.sumUnitLabel != nil {
                out += "  -------------------"
            }
            out += "\n"

            for year in type.perYearSamples.keys.sorted() {
                out += "  " + Fmt.pad("\(year)", 6)
                out += Fmt.num(type.perYearSamples[year] ?? 0, 11)
                if type.sumUnitLabel != nil {
                    let sum = type.perYearSum[year] ?? 0
                    out += "  " + Fmt.padLeft(Int(sum.rounded()).formatted(.number.grouping(.never)), 19)
                }
                out += "\n"
            }
            out += "\n"
        }

        out += "NOTES\n"
        out += "- Per-year totals are the raw sum of every sample from every source. Where the\n"
        out += "  phone and a watch both recorded, this double counts. See the per-day section\n"
        out += "  in mode B for the same figure split by source.\n"
        out += "- Sample counts come from fetching the samples; there is no count API. Types with\n"
        out += "  a long history take a while to scan.\n"

        return out
    }
}
