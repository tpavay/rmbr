import Foundation
import Photos
import HealthKit
import CoreLocation

enum PermissionState: String {
    case notDetermined = "NOT DETERMINED"
    case denied = "DENIED"
    case restricted = "RESTRICTED"
    case granted = "GRANTED"
    case limited = "GRANTED (limited selection)"
    case unavailable = "UNAVAILABLE ON THIS DEVICE"
    case asked = "ASKED (grant not readable)"
    case failed = "REQUEST FAILED"
}

/// All three permission requests, plus honest reporting of what each status
/// actually tells us. HealthKit in particular does not tell us.
enum Permissions {

    // MARK: Photos

    static func photoState() -> PermissionState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        case .limited: return .limited
        @unknown default: return .notDetermined
        }
    }

    static func requestPhotos() async -> PermissionState {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return photoState()
    }

    // MARK: Health

    /// Every type this spike reads. Kept in one place so the prompt and the
    /// surveys can never drift apart.
    static var healthReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distance)
        }
        return types
    }

    /// Whatever can be said about health access without putting a sheet on screen.
    static func healthStateWithoutAsking() -> PermissionState {
        HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
    }

    static func requestHealth() async -> (state: PermissionState, note: String) {
        guard HKHealthStore.isHealthDataAvailable() else {
            return (.unavailable, "HKHealthStore.isHealthDataAvailable() == false.")
        }
        let store = HKHealthStore()
        do {
            try await store.requestAuthorization(toShare: [], read: healthReadTypes)
        } catch {
            return (.failed, "requestAuthorization threw: \(error.localizedDescription)")
        }

        // getRequestStatus tells us whether iOS would still prompt. It does NOT
        // tell us whether read access was granted - that is deliberately hidden
        // so apps cannot infer the absence of health data from a refusal.
        let status: HKAuthorizationRequestStatus
        do {
            status = try await store.statusForAuthorizationRequest(toShare: [], read: healthReadTypes)
        } catch {
            return (.asked, "statusForAuthorizationRequest threw: \(error.localizedDescription)")
        }
        switch status {
        case .unnecessary:
            return (.asked, "iOS says it would not prompt again, so the sheet was answered. Whether READ was allowed is not knowable through the API - empty results below could mean 'denied' or 'no data'.")
        case .shouldRequest:
            return (.notDetermined, "iOS says it would still prompt, so the sheet was dismissed without an answer.")
        case .unknown:
            return (.asked, "HKAuthorizationRequestStatus == .unknown.")
        @unknown default:
            return (.asked, "HKAuthorizationRequestStatus == unrecognised value.")
        }
    }

    // MARK: Location

    static func locationStateDescription() -> String {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: return "NOT DETERMINED"
        case .restricted: return "RESTRICTED"
        case .denied: return "DENIED"
        case .authorizedWhenInUse: return "GRANTED (when in use - not enough for visit monitoring)"
        case .authorizedAlways: return "GRANTED (always)"
        @unknown default: return "UNRECOGNISED"
        }
    }
}
