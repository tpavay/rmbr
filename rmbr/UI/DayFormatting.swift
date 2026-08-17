import Foundation

/// Turns typed facts into the exact strings the page prints.
///
/// Everything here is a localized factual label or a format assembled from typed
/// values. There is no generated sentence, no interpretation and no adjective about the
/// day (RQ-002, RE-004).
enum DayFormatting {
    static func heading(for date: LocalDate, today: LocalDate) -> String {
        if date == today { return "Today" }
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        let calendar = Calendar(identifier: .gregorian)
        guard let resolved = calendar.date(from: components) else { return date.description }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: resolved)
    }

    static func monthTitle(_ month: Month) -> String {
        var components = DateComponents()
        components.year = month.year
        components.month = month.month
        components.day = 1
        let calendar = Calendar(identifier: .gregorian)
        guard let resolved = calendar.date(from: components) else { return month.description }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: resolved)
    }

    /// Prints a capture's own wall-clock time.
    ///
    /// A photograph's time is local components with no zone of their own, so it is
    /// formatted from those components directly rather than by converting an instant
    /// into the phone's current zone - otherwise a photograph taken abroad would read
    /// back at the wrong hour.
    static func time(_ sourceTime: SourceTime, in timeZone: TimeZone) -> String {
        let components = sourceTime.localComponents(defaultTimeZone: timeZone)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(
            year: 2000, month: 1, day: 1, hour: hour, minute: minute
        )) else { return String(format: "%02d:%02d", hour, minute) }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) sec"
    }

    /// How a moment states its own extent.
    ///
    /// A capture floor is printed as a floor and never as time spent somewhere: the
    /// words "spent", "for", "arrived" and "left" are not available to a moment whose
    /// only evidence is capture timestamps (RE-030, RQ-039).
    static func durationClaim(_ claim: DurationClaim, in timeZone: TimeZone) -> String? {
        switch claim {
        case .none:
            return nil
        case .captureFloor(let first, let last, _):
            let span = last.instant.timeIntervalSince(first.instant)
            guard span > 0 else { return nil }
            return "captures from \(time(first, in: timeZone)) to \(time(last, in: timeZone))"
                + " · at least \(duration(span)) between them"
        case .completedVisit(let arrival, let departure, _):
            return "\(duration(departure.timeIntervalSince(arrival))) here"
        case .recordedWorkout(let start, let end, _):
            return duration(end.timeIntervalSince(start))
        }
    }

    static func count(_ value: Int, singular: String, plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    /// The day's capture summary, stated from the raw counts.
    ///
    /// The counts describe what the library held, not what the page chose to show, so
    /// a day whose captures were mostly screenshots still reads as a busy day.
    static func captureSummary(_ counts: RawCaptureCounts) -> String? {
        var parts: [String] = []
        let stills = counts.photoCount
        if stills > 0 { parts.append(count(stills, singular: "photo", plural: "photos")) }
        if counts.videoCount > 0 {
            parts.append(count(counts.videoCount, singular: "video", plural: "videos"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    static func exclusionSummary(_ counts: MediaExclusionCounts) -> String? {
        var parts: [String] = []
        let screenshots = counts.count(of: .screenshot)
        let recordings = counts.count(of: .screenRecording)
        if screenshots > 0 {
            parts.append(count(screenshots, singular: "screenshot", plural: "screenshots"))
        }
        if recordings > 0 {
            parts.append(count(recordings, singular: "screen recording", plural: "screen recordings"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + " kept out of memories"
    }

    /// Up to three key facts, taken by the fixed category order.
    ///
    /// Milestone 1 can supply the named place and the capture summary. The workout,
    /// calendar, health and weather categories sit above and below them in the same
    /// order and stay empty because those sources are out of scope - not because the
    /// day had none of them.
    static func keyFacts(for day: Day) -> [String] {
        var facts: [String] = []

        if let place = day.moments.compactMap({ $0.place?.label.knownValue }).first {
            facts.append(place.text)
        }
        if let placeCount = day.facts.placeCount.knownValue, placeCount > 1 {
            facts.append(count(placeCount, singular: "place", plural: "places"))
        }
        if facts.count < 3, let counts = day.media.rawCounts.knownValue,
           let summary = captureSummary(counts) {
            facts.append(summary)
        }
        return Array(facts.prefix(3))
    }
}
