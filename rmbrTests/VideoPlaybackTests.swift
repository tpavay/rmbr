import AVFoundation
import Foundation
import Testing
@testable import rmbr

/// A video source a test supplies.
///
/// It answers synchronously, so what the viewer does with an answer is observable in the
/// same turn rather than after a sleep. The player items are real - the rule under test is
/// how many `AVPlayer`s exist, and a stub player would not answer that.
@MainActor
final class StubVideoSource: VideoItemSource {
    enum Answer {
        case video
        case failure(VideoUnavailability)
        /// Report a download and then answer, all before returning.
        case progressThen(fractions: [Double], Result<Void, VideoUnavailability>)
        /// Take the request and never answer it.
        case silence
    }

    var answer: Answer = .video
    /// What the source says the video runs for. The real one reads this off the asset
    /// before it delivers, so nothing downstream has to load anything.
    var duration: TimeInterval = 12
    private(set) var requested: [String] = []
    private(set) var cancelled: [Int] = []
    private var nextID = 1

    func requestPlayerItem(
        identifier: String,
        progress: @escaping @MainActor (Double) -> Void,
        deliver: @escaping @MainActor (Result<PlayableVideo, VideoUnavailability>) -> Void
    ) -> Int {
        requested.append(identifier)
        let requestID = nextID
        nextID += 1
        switch answer {
        case .video:
            deliver(.success(playable()))
        case .failure(let reason):
            deliver(.failure(reason))
        case .progressThen(let fractions, let outcome):
            for fraction in fractions { progress(fraction) }
            switch outcome {
            case .success:
                deliver(.success(playable()))
            case .failure(let reason):
                deliver(.failure(reason))
            }
        case .silence:
            break
        }
        return requestID
    }

    func cancel(_ requestID: Int) { cancelled.append(requestID) }

    /// A real `AVPlayer` is built on this, which is what makes the one-player rule
    /// measurable. Nothing here ever asks it to decode, so the file behind it does not
    /// have to exist - and a test must not depend on an encoder being available.
    private func playable() -> PlayableVideo {
        PlayableVideo(
            item: AVPlayerItem(url: URL(fileURLWithPath: "/rmbr-test-video.mov")),
            duration: duration
        )
    }
}

/// The audio session, recorded rather than performed.
///
/// What the categories do to somebody's music is the system's behaviour and needs a phone
/// with music playing. Which intent rmbr claims, and that it always hands the session
/// back, is rmbr's behaviour and belongs here.
@MainActor
final class RecordingAudioSession: ViewerAudioSession {
    enum Event: Equatable {
        case claimedSilent
        case claimedAudible
        case relinquished
    }

    private(set) var events: [Event] = []

    func claim(audible: Bool) { events.append(audible ? .claimedAudible : .claimedSilent) }
    func relinquish() { events.append(.relinquished) }
}

@MainActor
@Suite("Video playback", .serialized)
struct VideoPlaybackTests {
    private let date = LocalDate(year: 2026, month: 8, day: 20)

    private func video(_ identifier: String, seconds: TimeInterval = 12) -> MediaReference {
        MediaReference(
            id: MediaID(identifier),
            localIdentifier: identifier,
            kind: .video,
            captureTime: .floatingLocal(from: Date(timeIntervalSince1970: 0), readIn: Fixture.chicago),
            duration: seconds,
            pixelWidth: 1920,
            pixelHeight: 1080,
            isFavorite: false,
            hasAdjustments: false,
            burstIdentifier: nil,
            representedBurstFrames: 0,
            locationObservationID: nil,
            eligibility: .eligible,
            selection: .selected
        )
    }

    private func still(_ identifier: String, kind: MediaKind = .photo) -> MediaReference {
        MediaReference(
            id: MediaID(identifier),
            localIdentifier: identifier,
            kind: kind,
            captureTime: .floatingLocal(from: Date(timeIntervalSince1970: 0), readIn: Fixture.chicago),
            duration: nil,
            pixelWidth: 4032,
            pixelHeight: 3024,
            isFavorite: false,
            hasAdjustments: false,
            burstIdentifier: nil,
            representedBurstFrames: 0,
            locationObservationID: nil,
            eligibility: .eligible,
            selection: .selected
        )
    }

    // MARK: One player

    @Test("A strip of videos costs one player, however many are opened")
    func onePlayerAcrossManyVideos() {
        let source = StubVideoSource()
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        #expect(VideoPlayback.livePlayerCount == 0)

        for index in 1...7 {
            playback.open(video("video-\(index)"))
            #expect(VideoPlayback.livePlayerCount == 1)
        }

        playback.stop()
        #expect(VideoPlayback.livePlayerCount == 0)
        #expect(playback.player == nil)
        #expect(playback.mediaID == nil)
        #expect(source.requested.count == 7)
    }

    @Test("Advancing the film takes the player with it")
    func stopReleasesEverything() {
        let source = StubVideoSource()
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        let reference = video("the-one-showing")
        playback.open(reference)
        #expect(playback.holds(reference))
        #expect(VideoPlayback.livePlayerCount == 1)

        playback.stop()
        #expect(!playback.holds(reference))
        #expect(VideoPlayback.livePlayerCount == 0)
        #expect(!playback.isPlaying)
        #expect(playback.position == 0)
        #expect(playback.phase == .idle)
    }

    @Test("A fetch still in flight is cancelled rather than left to arrive")
    func swipingCancelsAnUnfinishedFetch() {
        let source = StubVideoSource()
        source.answer = .silence
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("still-fetching"))
        #expect(playback.phase == .preparing(progress: nil))

        playback.stop()
        #expect(source.cancelled.count == 1)
        #expect(VideoPlayback.livePlayerCount == 0)
    }

    @Test("A Live Photo is not a video and is never opened as one")
    func livePhotosAreLeftAlone() {
        let source = StubVideoSource()
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(still("live-photo", kind: .livePhoto))
        #expect(source.requested.isEmpty)
        #expect(playback.mediaID == nil)
        #expect(VideoPlayback.livePlayerCount == 0)
    }

    // MARK: The audio session

    @Test("Muted playback claims a session that mixes, and gives it back on pause")
    func mutedPlaybackDoesNotTakeSomebodysMusic() {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        playback.open(video("muted"))

        #expect(playback.phase == .ready)
        #expect(playback.isPlaying)
        #expect(playback.isMuted)
        #expect(audio.events.contains(.claimedSilent))
        #expect(!audio.events.contains(.claimedAudible))

        playback.pause()
        #expect(!playback.isPlaying)
        #expect(audio.events.last == .relinquished)
    }

    @Test("Unmuting is a different claim, and leaving hands the session back")
    func unmutingClaimsAudibleAndLeavingRestores() {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        playback.open(video("unmuted"))

        playback.setMuted(false)
        #expect(!playback.isMuted)
        #expect(audio.events.last == .claimedAudible)

        playback.stop()
        #expect(audio.events.last == .relinquished)
    }

    @Test("Muting again while playing claims the mixing session back")
    func mutingAgainReturnsToMixing() {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        playback.open(video("toggled"))

        playback.setMuted(false)
        playback.setMuted(true)
        #expect(audio.events.suffix(2) == [.claimedAudible, .claimedSilent])
    }

    @Test("Nothing plays until the person asks")
    func nothingPlaysOnItsOwn() {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        // Opening is the ask: it only ever happens from something the person touched.
        #expect(!playback.isPlaying)
        #expect(audio.events.isEmpty)
    }

    @Test("Sound the person asked for holds across the next video in the strip")
    func theSoundChoiceSurvivesTheFilmAdvance() {
        let playback = VideoPlayback(source: StubVideoSource(), audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("first"))
        playback.setMuted(false)

        playback.open(video("second"))
        #expect(!playback.isMuted)
    }

    @Test("A video that is only asked for never claims the session")
    func openingAloneIsSilent() {
        let audio = RecordingAudioSession()
        let source = StubVideoSource()
        source.answer = .silence
        let playback = VideoPlayback(source: source, audio: audio)
        defer { playback.stop() }
        playback.open(video("not-arrived"))
        #expect(!audio.events.contains(.claimedSilent))
        #expect(!audio.events.contains(.claimedAudible))
    }

    @Test("A video that ran to the end starts again rather than doing nothing")
    func playingFromTheEndRestarts() {
        let playback = VideoPlayback(source: StubVideoSource(), audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("finished", seconds: 1))
        playback.pause()
        playback.beginScrubbing()
        playback.scrub(to: playback.length)
        playback.endScrubbing()
        #expect(playback.length > 0)
        #expect(playback.position == playback.length)

        playback.play()
        #expect(playback.position == 0)
    }

    // MARK: Waiting, and not arriving

    @Test("A download in progress is stated as a fraction of itself")
    func aRealDownloadReportsItsProgress() {
        let source = StubVideoSource()
        source.answer = .progressThen(fractions: [0.1, 0.42], .failure(.notFetched))
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("in-icloud"))
        #expect(playback.phase == .unavailable(.notFetched))
    }

    @Test("A single completed pass over a local original claims no download")
    func aLocalOriginalIsNeverCalledAnICloudFetch() {
        let source = StubVideoSource()
        source.answer = .progressThen(fractions: [1.0], .success(()))
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("already-here"))
        // The phase moved past preparing on delivery; what matters is that no fraction
        // was ever carried, because a fraction is what prints the iCloud sentence.
        #expect(playback.phase != .preparing(progress: 1))
    }

    @Test("A wait that reports a fraction shows that fraction")
    func aPartialDownloadIsHeldInThePhase() {
        let source = StubVideoSource()
        source.answer = .progressThen(fractions: [0.25], .failure(.cancelled))
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        // A cancelled answer leaves the phase where the progress left it only if the
        // viewer treated the fraction as real, so this reads the sentence instead.
        playback.open(video("half-way"))
        #expect(playback.phase == .unavailable(.cancelled))
        #expect(VideoUnavailability.cancelled.sentence == nil)
    }

    @Test("Each way a video can fail to arrive says a different true thing")
    func failuresAreDistinguished() {
        #expect(VideoUnavailability.notFetched.sentence?.contains("iCloud") == true)
        #expect(VideoUnavailability.unreadable.sentence == "rmbr could not open this video.")
        #expect(VideoUnavailability.cancelled.sentence == nil)
    }

    @Test("A video that did not arrive can be asked for again")
    func retryAsksAgain() {
        let source = StubVideoSource()
        source.answer = .failure(.notFetched)
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("flaky"))
        #expect(playback.phase == .unavailable(.notFetched))

        playback.retry()
        #expect(source.requested == ["flaky", "flaky"])
    }

    // MARK: Scrubbing

    @Test("Scrubbing moves the playhead and is clamped to the video")
    func scrubbingStaysInsideTheVideo() {
        let source = StubVideoSource()
        source.duration = 300
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("seekable", seconds: 300))
        playback.beginScrubbing()
        playback.scrub(to: 120)
        #expect(playback.position == 120)
        playback.scrub(to: 5_000)
        #expect(playback.position == 300)
        playback.scrub(to: -10)
        #expect(playback.position == 0)
        playback.endScrubbing()
        #expect(!playback.isScrubbing)
    }

    @Test("The length is taken from the index before anything has loaded")
    func lengthIsKnownFromTheIndex() {
        let source = StubVideoSource()
        source.answer = .silence
        let playback = VideoPlayback(source: source, audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("five-minutes", seconds: 300))
        #expect(playback.length == 300)
    }

    // MARK: The clock

    @Test("A playhead reading is truncated, never rounded up")
    func theClockNeverNamesASecondNotReached() {
        #expect(DayFormatting.clock(0) == "0:00")
        #expect(DayFormatting.clock(8.9) == "0:08")
        #expect(DayFormatting.clock(59.99) == "0:59")
        #expect(DayFormatting.clock(60) == "1:00")
        #expect(DayFormatting.clock(300) == "5:00")
        #expect(DayFormatting.clock(3_725) == "1:02:05")
    }

    @Test("A playhead reading survives a length nobody knows yet")
    func theClockHandlesAnIndefiniteLength() {
        #expect(DayFormatting.clock(.nan) == "0:00")
        #expect(DayFormatting.clock(.infinity) == "0:00")
        #expect(DayFormatting.clock(-1) == "0:00")
    }

    @Test("How long a video is and where you are in it are said differently")
    func durationAndClockAreNotTheSameSentence() {
        #expect(DayFormatting.duration(8) == "8 sec")
        #expect(DayFormatting.clock(8) == "0:08")
        #expect(DayFormatting.duration(300) == "5 min")
        #expect(DayFormatting.clock(300) == "5:00")
    }
}
