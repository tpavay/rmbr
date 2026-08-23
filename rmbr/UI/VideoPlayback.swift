import AVFoundation
import Combine
import Photos
import SwiftUI

/// Why a video did not become playable.
///
/// Each case is a different true sentence. "Something went wrong" is not one of them:
/// a video sitting in iCloud that rmbr could not fetch is a different fact from a video
/// on this phone that will not open, and the person can act on the first.
enum VideoUnavailability: Error, Sendable, Hashable {
    /// The person swiped away, or the request was superseded. Nothing to say.
    case cancelled
    /// The original lives in iCloud and the download did not finish.
    case notFetched
    /// It is here and it will not open.
    case unreadable

    /// What the viewer prints. One sentence, stated rather than apologised for.
    var sentence: String? {
        switch self {
        case .cancelled:
            return nil
        case .notFetched:
            return "This video is stored in iCloud and rmbr could not finish downloading it."
        case .unreadable:
            return "rmbr could not open this video."
        }
    }
}

/// Everything video playback needs from PhotoKit.
///
/// A protocol for the same reason `ThumbnailImageSource` is one: the behaviour that
/// matters here - one request at a time, the waiting state while an iCloud original is
/// fetched, the failure state when it never arrives - is unreachable on a machine whose
/// library holds only local originals. Naming it lets those paths be driven.
@MainActor
protocol VideoItemSource: AnyObject {
    /// Issues one request for a playable item.
    ///
    /// `progress` reports an iCloud download from 0 to 1 and is never called for an
    /// original that is already here. `deliver` is called exactly once.
    func requestPlayerItem(
        identifier: String,
        progress: @escaping @MainActor (Double) -> Void,
        deliver: @escaping @MainActor (Result<AVPlayerItem, VideoUnavailability>) -> Void
    ) -> Int

    func cancel(_ requestID: Int)
}

/// Carries a value PhotoKit handed back on its own queue to the main actor.
///
/// PhotoKit does not promise which queue answers a player item request, and the item is
/// not touched between the callback and the hop.
private struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}

/// The real library.
///
/// The identifier is resolved off the main actor for the same reason `ThumbnailStore`
/// resolves its own there: `fetchAssets` is a Photos database read, and the frame the
/// person just tapped is still animating. The request identifier this hands back is its
/// own, because the PhotoKit one does not exist yet when the tap needs an answer.
final class PhotoKitVideoSource: VideoItemSource {
    private let manager = PHImageManager.default()
    private var resolving: [Int: Task<Void, Never>] = [:]
    private var issued: [Int: PHImageRequestID] = [:]
    private var nextRequestID = 1

    func requestPlayerItem(
        identifier: String,
        progress: @escaping @MainActor (Double) -> Void,
        deliver: @escaping @MainActor (Result<AVPlayerItem, VideoUnavailability>) -> Void
    ) -> Int {
        let token = nextRequestID
        nextRequestID += 1
        resolving[token] = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> Handoff<PHAsset?> in
                Handoff(value: PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.resolving[token] = nil
            guard let asset = found.value else {
                deliver(.failure(.unreadable))
                return
            }

            let options = PHVideoRequestOptions()
            // The viewer is a capture the person opened deliberately, which is the one
            // place rmbr spends the network. Inline thumbnails still never do.
            options.isNetworkAccessAllowed = true
            // The version the person would see in Photos, edits included.
            options.version = .current
            options.deliveryMode = .automatic
            options.progressHandler = { fraction, _, _, _ in
                Task { @MainActor in progress(fraction) }
            }

            self.issued[token] = self.manager.requestPlayerItem(forVideo: asset, options: options) {
                item, info in
                let handoff = Handoff(value: item)
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                let errored = info?[PHImageErrorKey] != nil
                Task { @MainActor [weak self] in
                    self?.issued[token] = nil
                    if let item = handoff.value {
                        deliver(.success(item))
                    } else if cancelled {
                        deliver(.failure(.cancelled))
                    } else {
                        // A request that asked for the network and still came back with
                        // nothing either never reached iCloud or was interrupted on the
                        // way; anything else is an original that will not open.
                        deliver(.failure(inCloud || !errored ? .notFetched : .unreadable))
                    }
                }
            }
        }
        return token
    }

    func cancel(_ requestID: Int) {
        resolving.removeValue(forKey: requestID)?.cancel()
        if let photoKitID = issued.removeValue(forKey: requestID) {
            manager.cancelImageRequest(photoKitID)
        }
    }
}

// MARK: - The audio session

/// The audio session decisions playing a video in the viewer makes, and nothing else.
///
/// A protocol so the policy - which category answers which intent, and that the session
/// is handed back rather than left held - is assertable. What the categories then *do*
/// to somebody's music is the system's behaviour, not rmbr's, and is only observable on
/// a phone that has music playing.
@MainActor
protocol ViewerAudioSession: AnyObject {
    /// Claims the session for playback that is either silent or audible.
    func claim(audible: Bool)
    /// Hands the session back and lets whatever was interrupted resume.
    func relinquish()
}

/// `AVAudioSession`, configured from the two intents the viewer has.
///
/// The default category a process starts in is `soloAmbient`, which Apple documents as
/// non-mixable: activating it interrupts other audio sessions. Playing a *muted* video
/// under it would therefore take somebody's podcast away to produce no sound at all,
/// which is why muted playback moves the session to `ambient` first. `ambient` mixes
/// with other apps and is silenced by the Ring/Silent switch, both of which are right
/// for a video the person has not asked to hear.
///
/// Unmuting is a different intent. The person tapped a control asking for this video's
/// sound, so `playback` is claimed: it is non-mixing, because two things playing at once
/// is not listening to either, and it stays audible with the Ring/Silent switch set to
/// silent, because a control somebody just tapped must not answer with silence.
/// `moviePlayback` is the mode Apple documents for movie content, and Apple documents it
/// as usable only with the `playback` category, so it travels with that claim alone.
///
/// The session is held only while sound could be produced. Pausing gives it back, which
/// is what lets an interrupted app resume at the pause rather than at the dismissal.
final class SystemViewerAudioSession: ViewerAudioSession {
    private typealias Configuration = (
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    )

    /// What the process was configured for before the viewer touched it.
    private var restore: Configuration?
    private var audible: Bool?

    func claim(audible wantsSound: Bool) {
        guard audible != wantsSound else { return }
        let session = AVAudioSession.sharedInstance()
        if restore == nil {
            restore = (session.category, session.mode, session.categoryOptions)
        }
        do {
            if wantsSound {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
            } else {
                // `ambient` mixes whether or not the flag is passed, but passing it is
                // what makes the intent readable back off the live session rather than
                // assumed from the category name. Apple documents the flag as explicitly
                // settable only on `playback`, `playAndRecord` and `multiRoute`, so a
                // release that refuses it falls back to the bare category, which mixes
                // just the same.
                do {
                    try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                } catch {
                    try session.setCategory(.ambient, mode: .default, options: [])
                }
            }
            try session.setActive(true)
            audible = wantsSound
        } catch {
            // A session rmbr could not claim is a video that plays without sound, not a
            // screen that fails. Nothing is said, because nothing the person did failed.
            audible = nil
        }
    }

    func relinquish() {
        guard audible != nil || restore != nil else { return }
        let session = AVAudioSession.sharedInstance()
        // Apple documents deactivating a session with running audio objects as stopping
        // them and returning an error, so the player is already paused by the time this
        // is reached.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let restore {
            try? session.setCategory(restore.category, mode: restore.mode, options: restore.options)
        }
        restore = nil
        audible = nil
    }

    /// What the session actually reports right now. Read by the diagnostics report so
    /// the categories above are evidence rather than an intention.
    static var description: String {
        let session = AVAudioSession.sharedInstance()
        var options: [String] = []
        if session.categoryOptions.contains(.mixWithOthers) { options.append("mixWithOthers") }
        if session.categoryOptions.contains(.duckOthers) { options.append("duckOthers") }
        options.append("raw=\(session.categoryOptions.rawValue)")
        return "\(session.category.rawValue) / \(session.mode.rawValue) [\(options.joined(separator: ", "))]"
    }
}

#if DEBUG
/// What the one-player rule and the audio session are actually doing, printed where the
/// reconstruction report is printed.
///
/// Instrumentation rather than product, and the same reason that report exists: the count
/// of live players and the category the session is really in are measurements, not claims
/// about the shape of the code.
@MainActor
func reportVideoPlayback(_ event: String) {
    print(
        "[video] \(event)"
            + " · players live: \(VideoPlayback.livePlayerCount)"
            + " · session: \(SystemViewerAudioSession.description)"
    )
}
#else
@MainActor
func reportVideoPlayback(_ event: String) {}
#endif

// MARK: - The one player

/// The single video player the viewer is allowed to own.
///
/// A paged strip keeps its neighbours alive, so a day with seven videos would hold seven
/// players if a frame owned one. This holds at most one, for the frame that is showing,
/// and every other frame stays the still it already was. Swiping tears the player down
/// rather than pausing it: a paused player still holds a decoder and a file, and the
/// person who swiped away is not coming back to the same second.
///
/// A video never begins on its own. `open` is only ever called from something the person
/// touched, and it begins muted (RQ-027).
@MainActor
@Observable
final class VideoPlayback {
    enum Phase: Equatable {
        /// Nothing has been asked for. The frame is a still with a play control on it.
        case idle
        /// Asked for, not here yet. `progress` is the iCloud download when PhotoKit
        /// reports one, and nil while it is merely opening something already local.
        case preparing(progress: Double?)
        case ready
        case unavailable(VideoUnavailability)
    }

    /// How many `AVPlayer`s this type currently holds across the whole app.
    ///
    /// One player at a time is the rule this class exists to keep, so the count is a
    /// fact the running app and the tests can both read rather than an argument from the
    /// shape of the code.
    private(set) static var livePlayerCount = 0

    private(set) var mediaID: MediaID?
    private(set) var phase: Phase = .idle
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    /// The video's length, taken from the index up front and corrected from the item
    /// once it is known - a slow-motion capture plays for longer than it was shot.
    private(set) var length: TimeInterval = 0
    /// Muted until the person says otherwise, and their choice then holds for as long as
    /// the viewer is open: having asked for sound once, they are not asked again.
    private(set) var isMuted = true
    private(set) var isScrubbing = false

    private let source: VideoItemSource
    private let audio: ViewerAudioSession
    private var requestID: Int?
    private var reference: MediaReference?
    private var timeObserver: Any?
    private var statusWatch: Task<Void, Never>?
    private var endWatch: Task<Void, Never>?
    private var failureWatch: Task<Void, Never>?
    /// Bumped by every teardown, so a fetch issued for a frame the person has already
    /// swiped past can never install its item over the frame they are looking at now.
    private var generation = 0

    init(
        source: VideoItemSource? = nil,
        audio: ViewerAudioSession = SystemViewerAudioSession()
    ) {
        self.source = source ?? VideoPlayback.librarySource()
        self.audio = audio
    }

    /// The real library, unless a debug build was launched asking to be lied to about
    /// where the originals live.
    private static func librarySource() -> VideoItemSource {
        let library = PhotoKitVideoSource()
        #if DEBUG
        if let simulated = SimulatedCloudVideoSource(wrapping: library) { return simulated }
        #endif
        return library
    }

    /// Whether this frame is the one holding the player.
    func holds(_ reference: MediaReference) -> Bool { mediaID == reference.id }

    /// Asks for a video and plays it once it arrives. Anything already open is released
    /// first, which is what keeps the count at one.
    func open(_ reference: MediaReference) {
        guard reference.kind == .video else { return }
        stop(keepingMute: true)
        generation += 1
        let issued = generation
        self.reference = reference
        mediaID = reference.id
        length = reference.duration ?? 0
        position = 0
        phase = .preparing(progress: nil)

        let issuedRequest = source.requestPlayerItem(
            identifier: reference.localIdentifier,
            progress: { [weak self] fraction in
                guard let self, self.generation == issued else { return }
                guard case .preparing = self.phase else { return }
                // PhotoKit reports a single completed pass for an original that was
                // already here, and "fetching from iCloud, 100 per cent" about a file
                // sitting on the phone is not true. A fraction short of the whole is
                // the only evidence that something is actually being downloaded.
                guard fraction > 0, fraction < 1 else { return }
                self.phase = .preparing(progress: fraction)
            },
            deliver: { [weak self] result in
                guard let self, self.generation == issued else { return }
                self.requestID = nil
                switch result {
                case .success(let item):
                    self.install(item)
                case .failure(let reason):
                    self.phase = .unavailable(reason)
                }
            }
        )
        // A source that answers before the call returns has already finished this
        // request, and the identifier it hands back then belongs to nothing.
        if generation == issued, case .preparing = phase { requestID = issuedRequest }
    }

    /// Asks again for the video that did not arrive.
    func retry() {
        guard let reference else { return }
        open(reference)
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player, phase == .ready else { return }
        // A video sitting on its last frame restarts rather than doing nothing, which is
        // what a play control that stays visible has to mean.
        if length > 0, position >= length - 0.05 {
            seek(to: 0)
        }
        audio.claim(audible: !isMuted)
        player.play()
        isPlaying = true
        reportVideoPlayback(isMuted ? "playing muted" : "playing with sound")
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        // The session is held only while sound could be produced, so pausing is what
        // lets an interrupted app resume - at the pause, not at the dismissal.
        audio.relinquish()
        reportVideoPlayback("paused")
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.isMuted = muted
        guard isPlaying else { return }
        audio.claim(audible: !muted)
        reportVideoPlayback(muted ? "muted" : "unmuted")
    }

    // MARK: Scrubbing

    func beginScrubbing() {
        isScrubbing = true
    }

    /// Moves the playhead while the finger is down. The position shown is the position
    /// asked for, so the label under the thumb never lags behind it.
    func scrub(to time: TimeInterval) {
        guard length > 0 else { return }
        position = min(max(0, time), length)
        seek(to: position)
    }

    func endScrubbing() {
        isScrubbing = false
    }

    /// Releases the player, the request behind it and the audio session.
    ///
    /// Called when the strip advances, when the viewer closes and when the app leaves
    /// the foreground. Everything the player was holding goes with it.
    func stop(keepingMute: Bool = true) {
        generation += 1
        if let requestID {
            source.cancel(requestID)
            self.requestID = nil
        }
        statusWatch?.cancel()
        statusWatch = nil
        endWatch?.cancel()
        endWatch = nil
        failureWatch?.cancel()
        failureWatch = nil
        if let player {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.replaceCurrentItem(with: nil)
            VideoPlayback.livePlayerCount -= 1
            reportVideoPlayback("released")
        }
        timeObserver = nil
        player = nil
        isPlaying = false
        position = 0
        length = 0
        mediaID = nil
        reference = nil
        phase = .idle
        isScrubbing = false
        if !keepingMute { isMuted = true }
        audio.relinquish()
    }

    // MARK: Private

    private func install(_ item: AVPlayerItem) {
        let player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        // Holding the last frame rather than blanking to black: the final frame of a
        // memory is still the memory.
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = true
        self.player = player
        VideoPlayback.livePlayerCount += 1
        reportVideoPlayback("opened \(reference?.localIdentifier ?? "?")")

        // Thirty times a second, which is what a scrubber has to move at to look like it
        // is following the video rather than sampling it.
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.position = time.seconds.isFinite ? max(0, time.seconds) : 0
                if let known = self.player?.currentItem?.duration.seconds,
                   known.isFinite, known > 0, abs(known - self.length) > 0.05 {
                    self.length = known
                }
            }
        }

        // `AVAsset.load` rather than watching `AVPlayerItem.status`: the item PhotoKit
        // hands over sits at `.unknown` until something asks the player to move, so
        // waiting on that status is waiting on a spinner that never resolves. Loading
        // the asset's own playability answers, and answers with a throw when it cannot.
        statusWatch = Task { @MainActor [weak self] in
            do {
                let (playable, assetDuration) = try await item.asset.load(.isPlayable, .duration)
                guard let self, !Task.isCancelled, self.player?.currentItem === item else { return }
                guard playable else {
                    self.phase = .unavailable(.unreadable)
                    return
                }
                let seconds = assetDuration.seconds
                if seconds.isFinite, seconds > 0 { self.length = seconds }
                self.phase = .ready
                // The tap that asked for the video is the tap that plays it: the fetch
                // finishing is not a second decision the person has to make.
                self.play()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .unavailable(.unreadable)
            }
        }

        endWatch = Task { @MainActor [weak self] in
            let ended = NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification
            )
            for await notification in ended {
                guard let self else { return }
                guard (notification.object as? AVPlayerItem) === item else { continue }
                self.isPlaying = false
                self.position = self.length
                self.audio.relinquish()
            }
        }

        // A video that opened and then stopped part way through is a failure the person
        // is watching happen, so it says so rather than sitting on a frozen frame.
        failureWatch = Task { @MainActor [weak self] in
            let failed = NotificationCenter.default.notifications(
                named: AVPlayerItem.failedToPlayToEndTimeNotification
            )
            for await notification in failed {
                guard let self else { return }
                guard (notification.object as? AVPlayerItem) === item else { continue }
                self.isPlaying = false
                self.audio.relinquish()
                self.phase = .unavailable(.unreadable)
            }
        }
    }

    private func seek(to time: TimeInterval) {
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
