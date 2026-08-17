import Foundation

/// Turns typed facts into the exact strings the page prints.
///
/// Everything here is a localized factual label or a format assembled from typed
/// values. There is no generated sentence, no interpretation and no adjective about the
/// day (RQ-002, RE-004).
enum DayFormatting {
    /// Local components are turned into a date and back into a string entirely inside one
    /// fixed zone, so what is printed depends on the components alone and never on where
    /// the phone happens to be. Building these is expensive enough that a scrolling row
    /// must not do it per frame.
    private static let componentCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fixedZone
        return calendar
    }()

    private static let fixedZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    private static let headingFormatter = formatter(dateFormat: "EEEE d MMMM yyyy")

    private static let monthFormatter = formatter(dateFormat: "MMMM yyyy")

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = fixedZone
        return formatter
    }()

    private static func formatter(dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.timeZone = fixedZone
        return formatter
    }

    static func heading(for date: LocalDate, today: LocalDate) -> String {
        if date == today { return "Today" }
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        guard let resolved = componentCalendar.date(from: components) else {
            return date.description
        }
        return headingFormatter.string(from: resolved)
    }

    static func monthTitle(_ month: Month) -> String {
        var components = DateComponents()
        components.year = month.year
        components.month = month.month
        components.day = 1
        guard let resolved = componentCalendar.date(from: components) else {
            return month.description
        }
        return monthFormatter.string(from: resolved)
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
        guard let date = componentCalendar.date(from: DateComponents(
            year: 2000, month: 1, day: 1, hour: hour, minute: minute
        )) else { return String(format: "%02d:%02d", hour, minute) }
        return timeFormatter.string(from: date)
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

    /// What a moment holds, for a moment the display budget showed nothing of.
    ///
    /// The budget is capped at ten captures for the whole day, so a day with many
    /// moments leaves later ones with no thumbnail at all. Such a moment states what it
    /// contains rather than offering "more" than nothing (RE-020).
    static func mediaComposition(of references: [MediaReference]) -> String? {
        let photographs = references.filter { $0.kind != .video }.count
        let videos = references.filter { $0.kind == .video }.count
        var parts: [String] = []
        if photographs > 0 {
            parts.append(count(photographs, singular: "photograph", plural: "photographs"))
        }
        if videos > 0 {
            parts.append(count(videos, singular: "video", plural: "videos"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " and ")
    }

    /// What a row says when no key fact could be stated.
    ///
    /// Limited access leaves the raw counts unknown, so a day can carry a cover and
    /// moments while having no fact to print. That day states what rmbr can see rather
    /// than reading as empty with the person's own photographs beside it; only a day
    /// that genuinely holds nothing says so (RQ-053).
    static func rowFallback(for day: Day) -> String {
        let visible = day.media.eligibleMediaIDs.count
        guard visible > 0 else { return "Nothing recorded" }
        return "\(count(visible, singular: "capture", plural: "captures")) rmbr can see"
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

/// What a row can say about a day nobody has opened.
///
/// Built from the archive survey's metadata signals and the stored ledger, never from a
/// composition, so listing a month costs nothing that opening a day costs. Counts are
/// counts of what rmbr can see, and say so whenever access is not exhaustive (RQ-053).
struct DayRowSummary: Sendable, Hashable {
    let placeName: String?
    /// Every credit owed by the label this row prints.
    let attributions: [String]
    /// What the library held that day, before display filtering. A day whose captures
    /// were all screenshots is a day that held those screenshots, not an empty one.
    let counts: RawCaptureCounts
    let placeCount: Int
    let hasExhaustiveCounts: Bool

    var headline: String {
        if let placeName { return placeName }
        if let summary = DayFormatting.captureSummary(counts) { return qualified(summary) }
        return hasExhaustiveCounts ? "Nothing recorded" : "Nothing rmbr can see here"
    }

    var detail: String? {
        var parts: [String] = []
        if placeName != nil, let summary = DayFormatting.captureSummary(counts) {
            parts.append(summary)
        }
        if placeCount > 1 {
            parts.append(DayFormatting.count(placeCount, singular: "place", plural: "places"))
        }
        guard !parts.isEmpty else { return nil }
        return qualified(parts.joined(separator: " · "))
    }

    var isEmpty: Bool { placeName == nil && counts.accessibleCaptureCount == 0 }

    /// Under limited access every figure here is drawn from the subset rmbr was shown,
    /// places as much as captures, so the qualification covers the whole line rather
    /// than only the part that happens to count photographs.
    private func qualified(_ text: String) -> String {
        hasExhaustiveCounts ? text : "\(text) rmbr can see"
    }
}
