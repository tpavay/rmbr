import Foundation

/// What the resolver did, so a thin day can say why rather than looking broken.
struct PlaceResolutionReport: Sendable, Hashable {
    var requested: Int = 0
    var resolved: Int = 0
    var unlabelled: Int = 0
    var failed: Int = 0
    /// Requests not made because the day's provider budget was already spent.
    var skippedForBudget: Int = 0
    /// Whether the labels counted as resolved reached the ledger on disk. A label held
    /// only in memory is not yet the permanent record the ledger promises to be, and
    /// saying so is what stops a day quietly losing its name at the next launch.
    var labelsPersisted: Bool = true
    /// The person left the day before the provider finished. Nothing further is asked
    /// for, and no caller should treat this as a completed pass.
    var wasCancelled: Bool = false
    /// Never the provider's own error. The request URL carries the API key and the
    /// coordinate, and a URL-loading error quotes that URL, so only a sanitised code
    /// reaches this field.
    var lastError: String?
}

/// Turns pending anchor coordinates into stored place labels.
///
/// Three rules shape this. Composition never waits on it, so a day is readable before
/// any label arrives. It never asks twice for a coordinate it has already answered,
/// because the ledger is permanent. And when the daily provider budget runs out it says
/// so out loud rather than quietly returning fewer names - a silent cap reads as "this
/// day had no places", which is a claim rmbr must never make by accident.
actor PlaceNameResolver {
    private let store: PlaceLabelLedgerStore
    private let credentials: GeoapifyCredentialStore
    private let session: URLSession
    private let dailyRequestBudget: Int
    private let minimumRequestInterval: TimeInterval

    private var ledger: PlaceLabelLedger
    private var lastRequestAt: Date?
    private var inFlight: Set<String> = []
    /// Labels held in memory that the ledger on disk does not have yet. The ledger is
    /// meant to be permanent, so a failed write is remembered and retried rather than
    /// left for a later lookup that will never come - the coordinate is answered in
    /// memory, so nothing would ask about it again.
    private var hasUnsavedChanges = false

    init(
        store: PlaceLabelLedgerStore = PlaceLabelLedgerStore(),
        credentials: GeoapifyCredentialStore = GeoapifyCredentialStore(),
        session: URLSession = GeoapifyReverseGeocoder.privateSession,
        // Geoapify's free tier allows 3,000 credits a day. Staying under it keeps the
        // budget from being exhausted by a background pass before the person opens
        // anything.
        dailyRequestBudget: Int = 2_500,
        minimumRequestInterval: TimeInterval = 0.25
    ) {
        self.store = store
        self.credentials = credentials
        self.session = session
        self.dailyRequestBudget = dailyRequestBudget
        self.minimumRequestInterval = minimumRequestInterval
        var loaded = store.load()
        // Labels named under a superseded cascade are dropped here, and the pruned ledger
        // is owed to disk so the same migration does not run on every launch.
        self.hasUnsavedChanges = loaded.adoptCurrentNamingPolicy()
        self.ledger = loaded
    }

    var currentLedger: PlaceLabelLedger { ledger }

    var hasCredential: Bool { credentials.hasKey }

    /// Resolves what it can and returns the updated ledger.
    ///
    /// - Parameter lookups: anchors a composition wanted labels for. Duplicates and
    ///   coordinates already in the ledger are dropped before any request is made.
    func resolve(_ lookups: [PendingPlaceLookup]) async -> (PlaceLabelLedger, PlaceResolutionReport) {
        var report = PlaceResolutionReport()
        persistIfNeeded(into: &report)
        guard let apiKey = credentials.read() else {
            report.lastError = "No Geoapify key stored on this device."
            return (ledger, report)
        }

        var pending: [Coordinate] = []
        var claimed: [String] = []
        for lookup in lookups {
            let key = "\(lookup.coordinate.latitude),\(lookup.coordinate.longitude)"
            guard ledger.needsLookup(lookup.coordinate), !inFlight.contains(key) else { continue }
            // Two anchors inside the ledger's match distance of each other resolve to the
            // same entry, so only ask once for the pair.
            if pending.contains(where: { $0.distance(to: lookup.coordinate) <= PlaceLabelLedger.matchDistanceMetres }) {
                continue
            }
            pending.append(lookup.coordinate)
            inFlight.insert(key)
            claimed.append(key)
        }
        // Release only what this call claimed: a concurrent resolve may be holding
        // coordinates of its own across the same suspension points.
        defer { for key in claimed { inFlight.remove(key) } }

        guard !pending.isEmpty else { return (ledger, report) }

        let geocoder = GeoapifyReverseGeocoder(apiKey: apiKey, session: session)
        var spent = RequestBudget.spentToday()

        for coordinate in pending {
            if Task.isCancelled {
                report.wasCancelled = true
                break
            }
            guard spent < dailyRequestBudget else {
                report.skippedForBudget += 1
                continue
            }
            // The budget is spent only once the wait has completed, so a pass abandoned
            // while waiting costs the person nothing.
            guard await throttle() else {
                report.wasCancelled = true
                break
            }
            report.requested += 1
            spent += 1
            RequestBudget.recordSpend()
            do {
                if let label = try await geocoder.label(for: coordinate) {
                    ledger.record(.resolved(label), at: coordinate)
                    hasUnsavedChanges = true
                    report.resolved += 1
                } else {
                    ledger.record(.unlabelled(attemptedAt: Date()), at: coordinate)
                    hasUnsavedChanges = true
                    report.unlabelled += 1
                }
            } catch where Self.isCancellation(error) {
                report.wasCancelled = true
                break
            } catch {
                // A failure leaves the coordinate unanswered rather than recording a
                // wrong or empty label, so a later run can try again (RQ-052).
                report.failed += 1
                report.lastError = Self.sanitised(error)
            }
        }

        persistIfNeeded(into: &report)
        return (ledger, report)
    }

    /// Retries a write the ledger still owes, without asking the provider anything.
    ///
    /// A day whose label lives only in memory reads correctly until the app exits and
    /// then loses the name it froze, and no later lookup would recover it, because the
    /// coordinate already has an answer in memory. Retrying on its own schedule is what
    /// closes that gap.
    @discardableResult
    func persistPendingLabels() -> Bool {
        var report = PlaceResolutionReport()
        persistIfNeeded(into: &report)
        return report.labelsPersisted
    }

    private func persistIfNeeded(into report: inout PlaceResolutionReport) {
        guard hasUnsavedChanges else {
            report.labelsPersisted = true
            return
        }
        do {
            try store.save(ledger)
            hasUnsavedChanges = false
            report.labelsPersisted = true
        } catch {
            // The labels stay in memory, so the day still reads correctly now, but the
            // ledger did not become permanent and the write is owed until it succeeds.
            report.labelsPersisted = false
            report.lastError = "Resolved labels could not be written to the ledger."
        }
    }

    /// Turns a failure into something safe to print.
    ///
    /// `URLError` carries the failing URL, which holds the API key and the coordinate
    /// that was looked up, and the report is rendered on screen.
    /// Whether a failure is the person having walked away rather than the provider
    /// answering badly. `URLSession` reports a cancelled task as a `URLError`, not as a
    /// `CancellationError`, so both shapes count.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func sanitised(_ error: Error) -> String {
        switch error {
        case let failure as GeoapifyReverseGeocoder.Failure:
            switch failure {
            case .missingAPIKey: return "No Geoapify key stored on this device."
            case .badResponse(let status): return "The provider answered with HTTP \(status)."
            case .decoding: return "The provider's answer could not be read."
            }
        case let urlError as URLError:
            return "The request did not complete (URLError \(urlError.code.rawValue))."
        case is CancellationError:
            return "The lookup was cancelled."
        default:
            return "The lookup failed."
        }
    }

    /// Waits out the minimum interval, answering whether the wait completed.
    private func throttle() async -> Bool {
        guard let last = lastRequestAt else {
            lastRequestAt = Date()
            return !Task.isCancelled
        }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed < minimumRequestInterval {
            do {
                try await Task.sleep(for: .seconds(minimumRequestInterval - elapsed))
            } catch {
                return false
            }
        }
        lastRequestAt = Date()
        return !Task.isCancelled
    }
}

/// A per-calendar-day count of provider requests, so a runaway pass cannot spend the
/// whole free tier in one background sweep.
/// One date and one count, rewritten when the date rolls over, so the record of what has
/// been spent never grows with the number of days the app has been used.
enum RequestBudget {
    private static let dateKey = "rmbr.geoapify.spendDate"
    private static let countKey = "rmbr.geoapify.spendCount"

    private static var todayStamp: String {
        LocalDate(instant: Date(), in: .current).description
    }

    static func spentToday() -> Int {
        spent(on: todayStamp, in: .standard)
    }

    static func recordSpend() {
        let defaults = UserDefaults.standard
        let stamp = todayStamp
        let spent = spent(on: stamp, in: defaults)
        defaults.set(stamp, forKey: dateKey)
        defaults.set(spent + 1, forKey: countKey)
    }

    private static func spent(on stamp: String, in defaults: UserDefaults) -> Int {
        guard defaults.string(forKey: dateKey) == stamp else { return 0 }
        return defaults.integer(forKey: countKey)
    }
}
