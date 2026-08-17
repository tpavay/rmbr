import Foundation
@testable import rmbr

/// Builds normalised capture records without a photo library.
///
/// The engine is written against `CaptureRecord` rather than `PHAsset` precisely so
/// this is possible: every rule below is exercised on a laptop, deterministically, with
/// no device, no permission sheet and no network.
enum Fixture {
    static let chicago = TimeZone(identifier: "America/Chicago")!
    static let baltimore = TimeZone(identifier: "America/New_York")!

    static func capture(
        _ time: String,
        on date: LocalDate,
        in timeZone: TimeZone,
        kind: MediaKind = .photo,
        coordinate: Coordinate? = nil,
        accuracy: Double? = nil,
        isScreenshot: Bool = false,
        isScreenRecording: Bool = false,
        isHidden: Bool = false,
        isFavorite: Bool = false,
        hasAdjustments: Bool = false,
        duration: TimeInterval? = nil,
        identifier: String? = nil
    ) -> CaptureRecord {
        let parts = time.split(separator: ":").map { Int($0) ?? 0 }
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        components.hour = parts.count > 0 ? parts[0] : 0
        components.minute = parts.count > 1 ? parts[1] : 0
        components.second = parts.count > 2 ? parts[2] : 0
        components.timeZone = timeZone
        let instant = RmbrCalendar.calendar(in: timeZone).date(from: components)!
        let id = identifier ?? "\(date)-\(time)-\(kind.rawValue)"

        return CaptureRecord(
            id: MediaID(id),
            localIdentifier: id,
            kind: kind,
            captureTime: .floatingLocal(from: instant, readIn: timeZone),
            instant: instant,
            duration: duration,
            pixelWidth: 4032,
            pixelHeight: 3024,
            isFavorite: isFavorite,
            hasAdjustments: hasAdjustments,
            isScreenshot: isScreenshot,
            isScreenRecording: isScreenRecording,
            isHidden: isHidden,
            burstIdentifier: nil,
            isRepresentativeBurstFrame: true,
            representedBurstFrames: 0,
            coordinate: coordinate,
            horizontalAccuracyMetres: accuracy
        )
    }

    static func context(
        timeZone: TimeZone = chicago,
        fullAccess: Bool = true,
        labels: DayComposer.PlaceLabelLookup = .empty
    ) -> DayComposer.Context {
        DayComposer.Context(
            timeZone: timeZone,
            hasFullLibraryAccess: fullAccess,
            placeLabels: labels,
            composedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    static func label(_ text: String, specificity: PlaceSpecificity = .venue) -> ResolvedPlaceLabel {
        ResolvedPlaceLabel(
            text: text,
            specificity: specificity,
            origin: .providerPOI,
            confidence: nil,
            provider: "geoapify",
            attribution: OpenStreetMap.attribution,
            fetchedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    /// A lookup that names everything, for tests about what a label does once it exists.
    static func namingEverything(_ text: String) -> DayComposer.PlaceLabelLookup {
        DayComposer.PlaceLabelLookup { _ in label(text) }
    }

    /// Moves a coordinate north by a number of metres.
    static func offset(_ coordinate: Coordinate, metresNorth: Double) -> Coordinate {
        Coordinate(
            latitude: coordinate.latitude + metresNorth / 110_574,
            longitude: coordinate.longitude
        )
    }
}
