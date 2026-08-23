#if DEBUG
import AVFoundation
import Foundation

/// A video source that pretends the original is in iCloud.
///
/// Every original in a simulator's library is local, so the two states a video that is
/// *not* on the phone produces - the wait with a real percentage on it, and the failure
/// at the end of a wait that came to nothing - cannot be reached there any other way.
/// This decorates the real source and drives exactly those two paths through the same
/// code the app uses to show them.
///
/// It is compiled out of a release build entirely, and inert in a debug one unless a
/// launch argument turns it on:
///
///     -rmbrSimulateCloudFetch <seconds>    report a download taking this long
///     -rmbrSimulateCloudFailure            and end it with nothing, rather than a video
final class SimulatedCloudVideoSource: VideoItemSource {
    private let wrapped: VideoItemSource
    private let seconds: Double
    private let fails: Bool
    private var work: [Int: Task<Void, Never>] = [:]
    private var forwarded: [Int: Int] = [:]
    private var nextRequestID = 1

    init?(
        wrapping wrapped: VideoItemSource,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard let flag = arguments.firstIndex(of: "-rmbrSimulateCloudFetch"),
              flag + 1 < arguments.count,
              let seconds = Double(arguments[flag + 1]), seconds > 0
        else { return nil }
        self.wrapped = wrapped
        self.seconds = seconds
        self.fails = arguments.contains("-rmbrSimulateCloudFailure")
    }

    func requestPlayerItem(
        identifier: String,
        progress: @escaping @MainActor (Double) -> Void,
        deliver: @escaping @MainActor (Result<PlayableVideo, CaptureUnavailability>) -> Void
    ) -> Int {
        let requestID = nextRequestID
        nextRequestID += 1
        work[requestID] = Task { @MainActor [weak self] in
            let steps = 20
            for step in 1...steps {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.seconds / Double(steps)))
                guard !Task.isCancelled else { return }
                // Never a whole one: PhotoKit's own completed pass is what the viewer
                // reads as "nothing was downloaded", and this is a download.
                progress(Double(step) / Double(steps + 1))
            }
            guard !Task.isCancelled, let self else { return }
            guard !self.fails else {
                deliver(.failure(.notFetched))
                return
            }
            self.forwarded[requestID] = self.wrapped.requestPlayerItem(
                identifier: identifier,
                progress: { _ in },
                deliver: deliver
            )
        }
        return requestID
    }

    func cancel(_ requestID: Int) {
        work.removeValue(forKey: requestID)?.cancel()
        if let real = forwarded.removeValue(forKey: requestID) { wrapped.cancel(real) }
    }
}
#endif
