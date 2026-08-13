import Foundation
import CoreLocation

/// The blocking question this answers: can a freshly installed app see where the
/// captain was BEFORE it was installed? Everything else in the survey is a count.
/// This one changes the product.
final class LocationProbe: NSObject, CLLocationManagerDelegate {

    /// How long mode A sits and listens for visit callbacks before drawing a conclusion.
    static let visitObservationWindow: TimeInterval = 8

    /// Main-actor pinned so CLLocationManager is created on a thread with a live
    /// run loop, which is where its delegate callbacks are then delivered.
    @MainActor static let shared = LocationProbe()

    private let manager = CLLocationManager()

    private(set) var monitoringStartedAt: Date?
    private(set) var visits: [CLVisit] = []
    private(set) var fixes: [CLLocation] = []
    private(set) var errors: [String] = []
    private(set) var servicesEnabled: Bool?

    override private init() {
        super.init()
        manager.delegate = self
    }

    @MainActor
    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Ask for When In Use, then escalate to Always, which is what visit monitoring
    /// requires. Polls rather than waiting on the delegate: iOS does not reliably
    /// call back for the deferred Always prompt, and a hung probe teaches us nothing.
    @MainActor
    func requestAuthorization() async {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            await waitWhile(status: .notDetermined, timeout: 60)
        }
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
            await waitWhile(status: .authorizedWhenInUse, timeout: 20)
        }
    }

    @MainActor
    private func waitWhile(status: CLAuthorizationStatus, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.authorizationStatus == status && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Start every future-facing location API CoreLocation offers, then sit and see
    /// whether anything from the past turns up. It will not. We measure it anyway.
    @MainActor
    func probe(progress: @escaping @Sendable (String) -> Void) async {
        let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        servicesEnabled = enabled

        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse else {
            return
        }

        visits.removeAll()
        fixes.removeAll()
        errors.removeAll()
        monitoringStartedAt = Date()
        manager.startMonitoringVisits()
        manager.requestLocation()

        progress("Location: listening for visit callbacks for \(Int(Self.visitObservationWindow))s…")
        try? await Task.sleep(for: .seconds(Self.visitObservationWindow))
        manager.stopMonitoringVisits()
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        visits.append(visit)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fixes.append(contentsOf: locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errors.append(error.localizedDescription)
    }

    // MARK: Report

    @MainActor
    func report() -> String {
        var out = Fmt.rule("location") + "\n\n"

        out += "Authorisation        : \(Permissions.locationStateDescription())\n"
        out += "Location services on : \(servicesEnabled.map { $0 ? "yes" : "NO" } ?? "not checked")\n"

        guard monitoringStartedAt != nil else {
            out += "\nVisit monitoring was NOT started (no location authorisation).\n\n"
            out += verdict(historicalVisitsSeen: 0, inProgressVisitsSeen: 0, monitoringRan: false)
            return out
        }

        out += "Visit monitoring at  : \(Fmt.stamp(monitoringStartedAt))\n"
        out += "Observation window   : \(Int(Self.visitObservationWindow))s\n"
        out += "CLVisit callbacks    : \(visits.count)\n"
        out += "Live location fixes  : \(fixes.count)"
        if let fix = fixes.last {
            out += String(format: " (last: %.4f, %.4f at %@)", fix.coordinate.latitude, fix.coordinate.longitude, Fmt.stamp(fix.timestamp))
        }
        out += "\n"
        if !errors.isEmpty {
            out += "Errors               : \(errors.joined(separator: " | "))\n"
        }

        var historical = 0
        var inProgress = 0
        if !visits.isEmpty {
            out += "\nVISITS RECEIVED\n"
            for visit in visits {
                let started = monitoringStartedAt ?? Date()
                let isPast = visit.arrivalDate < started && visit.arrivalDate != .distantPast
                let stillHere = visit.departureDate == .distantFuture
                if isPast && !stillHere { historical += 1 } else { inProgress += 1 }
                out += String(
                    format: "  arrived %@  departed %@  %.4f, %.4f  ±%.0fm  [%@]\n",
                    visit.arrivalDate == .distantPast ? "unknown" : Fmt.stamp(visit.arrivalDate),
                    stillHere ? "still there" : Fmt.stamp(visit.departureDate),
                    visit.coordinate.latitude,
                    visit.coordinate.longitude,
                    visit.horizontalAccuracy,
                    isPast && !stillHere ? "PAST VISIT" : "current/in-progress"
                )
            }
        }

        out += "\n" + verdict(historicalVisitsSeen: historical, inProgressVisitsSeen: inProgress, monitoringRan: true)
        return out
    }

    @MainActor
    private func verdict(historicalVisitsSeen: Int, inProgressVisitsSeen: Int, monitoringRan: Bool) -> String {
        var out = "VERDICT ON PRE-INSTALL LOCATION HISTORY\n\n"

        out += "API surface, checked against CoreLocation as shipped:\n"
        out += "  startMonitoringVisits()                  future only, delivers visits that\n"
        out += "                                           begin after monitoring starts\n"
        out += "  startMonitoringSignificantLocationChanges() future only\n"
        out += "  CLLocationUpdate.liveUpdates             future only, as named\n"
        out += "  CLMonitor                                future only, region entry/exit\n"
        out += "  manager.location                         a single most-recent fix, present tense\n"
        out += "  (no fetch, query, history or since-date variant exists on any of them)\n\n"

        out += "iOS does keep Significant Locations, visible under Settings > Privacy &\n"
        out += "Security > Location Services > System Services. No public API reads it.\n\n"

        if !monitoringRan {
            out += "EMPIRICAL RESULT: not run - location authorisation was not granted, so this\n"
            out += "run neither confirms nor refutes. Re-run with location allowed.\n"
        } else if historicalVisitsSeen == 0 {
            out += "EMPIRICAL RESULT: CONFIRMED. \(inProgressVisitsSeen) visit callback(s) arrived in the\n"
            out += "observation window and none of them described a completed visit that began\n"
            out += "before monitoring started. No pre-install visit history was reachable.\n"
        } else {
            out += "EMPIRICAL RESULT: REFUTED, partially. \(historicalVisitsSeen) callback(s) described a\n"
            out += "completed visit that began before monitoring started. Read the visit list above\n"
            out += "carefully before believing it - this is the interesting outcome.\n"
        }

        out += "\nCONSEQUENCE IF CONFIRMED\n"
        out += "A rebuilt past day has a place ONLY where a photograph carried coordinates.\n"
        out += "Days with no geotagged photo have no place at all, and no amount of permission\n"
        out += "granting changes that retroactively. Location coverage of the past is exactly\n"
        out += "the GPS% column in the photo table above, and nothing more. Days from here\n"
        out += "forward can be richer, but only if the app is installed and monitoring.\n"
        return out
    }
}
