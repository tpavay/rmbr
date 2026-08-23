#if DEBUG
import Foundation
import UIKit

/// A thumbnail source that pretends the originals are in iCloud.
///
/// Every original in a simulator's library is local, so the states a photograph that is
/// *not* on the phone produces - the wait with a real percentage on it, the failure at
/// the end of a wait that came to nothing, and the permanent blur of a surface that
/// refused the network - cannot be reached there any other way. This decorates the real
/// source and drives exactly those paths through the same code the app uses to show them.
///
/// What it simulates faithfully is the *sequence of passes*, which is what every state
/// downstream is driven by. It cannot simulate the pixels: a simulator's degraded pass
/// comes from an original sitting on the disk, so the frame under the ring is sharper
/// than a real offloaded capture's would be.
///
/// It shares the video simulation's launch arguments, because an offloaded library is
/// offloaded for both:
///
///     -rmbrSimulateCloudFetch <seconds>    report a download taking this long
///     -rmbrSimulateCloudFailure            and end it with nothing, rather than pixels
///
/// It is compiled out of a release build entirely.
@MainActor
final class SimulatedCloudImageSource: ThumbnailImageSource {
    private let wrapped: ThumbnailImageSource
    private let seconds: Double
    private let fails: Bool

    /// One simulated fetch: the real request behind it, the full-quality pass it is
    /// holding back, and whether the download it is pretending to make has finished.
    private struct Pending {
        var forwarded: Int?
        var held: UIImage?
        var downloaded = false
        var deliver: @MainActor (ThumbnailUpdate) -> Void
    }

    private var pending: [Int: Pending] = [:]
    private var work: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 1

    init?(
        wrapping wrapped: ThumbnailImageSource,
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

    func resolve(_ identifiers: [String]) async -> [String] {
        await wrapped.resolve(identifiers)
    }

    func requestImage(
        identifier: String,
        targetSize: CGSize,
        allowNetwork: Bool,
        deliver: @escaping @MainActor (ThumbnailUpdate) -> Void
    ) -> Int {
        let token = nextRequestID
        nextRequestID += 1
        pending[token] = Pending(deliver: deliver)

        let forwarded = wrapped.requestImage(
            identifier: identifier,
            targetSize: targetSize,
            allowNetwork: allowNetwork
        ) { [weak self] update in
            guard let self else { return }
            switch update {
            case .image(let image, let isDegraded):
                guard !allowNetwork else {
                    if isDegraded {
                        deliver(update)
                    } else {
                        self.pending[token]?.held = image
                        self.flush(token)
                    }
                    return
                }
                // A surface that refused the network is answered the way PhotoKit answers
                // one: the local placeholder, and then the news that the original stayed
                // in iCloud. Nothing full-quality ever arrives.
                deliver(.image(image, isDegraded: true))
                deliver(.unavailable(.notFetched))
                self.finish(token)
            case .fetching:
                // The real library's own passes are not the story being told here.
                break
            case .unavailable(let reason):
                deliver(.unavailable(reason))
                self.finish(token)
            }
        }
        pending[token]?.forwarded = forwarded

        guard allowNetwork else { return token }
        work[token] = Task { @MainActor [weak self] in
            let steps = 20
            for step in 1...steps {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.seconds / Double(steps)))
                guard !Task.isCancelled else { return }
                // Never a whole one: PhotoKit's own completed pass is what the store
                // reads as "nothing was downloaded", and this is a download.
                deliver(.fetching(Double(step) / Double(steps + 1)))
            }
            guard !Task.isCancelled, let self else { return }
            guard !self.fails else {
                deliver(.unavailable(.notFetched))
                self.finish(token)
                return
            }
            self.pending[token]?.downloaded = true
            self.flush(token)
        }
        return token
    }

    func cancel(_ requestID: Int) {
        work.removeValue(forKey: requestID)?.cancel()
        if let forwarded = pending.removeValue(forKey: requestID)?.forwarded {
            wrapped.cancel(forwarded)
        }
    }

    func startCaching(_ identifiers: [String], targetSize: CGSize) {
        wrapped.startCaching(identifiers, targetSize: targetSize)
    }

    func stopCaching(_ identifiers: [String], targetSize: CGSize) {
        wrapped.stopCaching(identifiers, targetSize: targetSize)
    }

    func releaseResolved() {
        for token in Array(work.keys) { work.removeValue(forKey: token)?.cancel() }
        pending.removeAll()
        wrapped.releaseResolved()
    }

    /// Hands over the full-quality pass once both the library and the pretend download
    /// have finished, whichever of them was last.
    private func flush(_ token: Int) {
        guard let entry = pending[token], entry.downloaded, let image = entry.held else { return }
        entry.deliver(.image(image, isDegraded: false))
        finish(token)
    }

    private func finish(_ token: Int) {
        work.removeValue(forKey: token)?.cancel()
        pending.removeValue(forKey: token)
    }
}
#endif
