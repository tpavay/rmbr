import Foundation
import Photos

/// What the person granted over their photo library.
enum PhotoLibraryAccess: Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    /// The whole library. Only this licenses rmbr to present a count as exhaustive.
    case full
    /// A chosen subset. Every count is a count of what rmbr can see, not of what exists.
    case limited

    var canRead: Bool {
        switch self {
        case .full, .limited: true
        case .notDetermined, .denied, .restricted: false
        }
    }

    var isExhaustive: Bool { self == .full }

    init(status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .full
        case .limited: self = .limited
        @unknown default: self = .denied
        }
    }
}

enum PhotoLibraryAuthorization {
    static var current: PhotoLibraryAccess {
        PhotoLibraryAccess(status: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Asks for full-library access.
    ///
    /// rmbr asks for photographs and nothing else in milestone 1: the day it rebuilds
    /// is made of photographs, so that is the only permission whose refusal would leave
    /// the app with nothing to show.
    static func request() async -> PhotoLibraryAccess {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoLibraryAccess(status: status)
    }
}
