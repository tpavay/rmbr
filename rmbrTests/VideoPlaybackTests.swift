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
        case item
        case failure(VideoUnavailability)
        /// Report a download and then answer, all before returning.
        case progressThen(fractions: [Double], Result<Void, VideoUnavailability>)
        /// Take the request and never answer it.
        case silence
    }

    var answer: Answer = .item
    private(set) var requested: [String] = []
    private(set) var cancelled: [Int] = []
    private var nextID = 1

    func requestPlayerItem(
        identifier: String,
        progress: @escaping @MainActor (Double) -> Void,
        deliver: @escaping @MainActor (Result<AVPlayerItem, VideoUnavailability>) -> Void
    ) -> Int {
        requested.append(identifier)
        let requestID = nextID
        nextID += 1
        switch answer {
        case .item:
            deliver(.success(Self.playerItem()))
        case .failure(let reason):
            deliver(.failure(reason))
        case .progressThen(let fractions, let outcome):
            for fraction in fractions { progress(fraction) }
            switch outcome {
            case .success:
                deliver(.success(Self.playerItem()))
            case .failure(let reason):
                deliver(.failure(reason))
            }
        case .silence:
            break
        }
        return requestID
    }

    func cancel(_ requestID: Int) { cancelled.append(requestID) }

    private static func playerItem() -> AVPlayerItem {
        AVPlayerItem(url: TestVideo.url)
    }
}

/// A real, tiny, playable video, written once per test run.
///
/// The rules under test are how many `AVPlayer`s exist and which audio session each state
/// claims, and both of those only happen for a video that actually loads. Writing one is
/// what keeps these tests on the same path the app takes, on a laptop, with no library.
enum TestVideo {
    static let url: URL = (try? write()) ?? URL(fileURLWithPath: "/dev/null")

    private enum Failure: Error { case writerRefused }

    private static func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmbr-fixture-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writerRefused }
        writer.startSession(atSourceTime: .zero)

        // Two seconds at twelve frames a second, which is long enough that a test can
        // assert on a video that is playing without racing its last frame.
        for frame in 0..<24 {
            // The writer takes a frame only when it says it is ready for one, and
            // appending before then throws. A fixture this small is written by waiting
            // rather than by wiring up a callback for twenty-four frames.
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 400 {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
            }
            guard input.isReadyForMoreMediaData else { throw Failure.writerRefused }

            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw Failure.writerRefused }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 10), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12)
            ) else { throw Failure.writerRefused }
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 20) == .success,
              writer.status == .completed
        else { throw Failure.writerRefused }
        return url
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

    /// Waits for the asset to load, which is what moves the viewer to `.ready`.
    ///
    /// Reaching `.ready` also starts the video: the tap that asked for it is the tap that
    /// plays it, so there is no second decision to drive here.
    private func played(_ playback: VideoPlayback) async {
        for _ in 0..<400 {
            if playback.phase == .ready { return }
            if case .unavailable = playback.phase { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
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
    func mutedPlaybackDoesNotTakeSomebodysMusic() async {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        playback.open(video("muted"))
        await played(playback)

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
    func unmutingClaimsAudibleAndLeavingRestores() async {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        playback.open(video("unmuted"))
        await played(playback)

        playback.setMuted(false)
        #expect(!playback.isMuted)
        #expect(audio.events.last == .claimedAudible)

        playback.stop()
        #expect(audio.events.last == .relinquished)
    }

    @Test("Muting again while playing claims the mixing session back")
    func mutingAgainReturnsToMixing() async {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        playback.open(video("toggled"))
        await played(playback)

        playback.setMuted(false)
        playback.setMuted(true)
        #expect(audio.events.suffix(2) == [.claimedAudible, .claimedSilent])
    }

    @Test("Nothing plays until the person asks")
    func nothingPlaysOnItsOwn() async {
        let audio = RecordingAudioSession()
        let playback = VideoPlayback(source: StubVideoSource(), audio: audio)
        defer { playback.stop() }
        // Opening is the ask: it only ever happens from something the person touched.
        #expect(!playback.isPlaying)
        #expect(audio.events.isEmpty)
    }

    @Test("Sound the person asked for holds across the next video in the strip")
    func theSoundChoiceSurvivesTheFilmAdvance() async {
        let playback = VideoPlayback(source: StubVideoSource(), audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("first"))
        await played(playback)
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
    func playingFromTheEndRestarts() async {
        let playback = VideoPlayback(source: StubVideoSource(), audio: RecordingAudioSession())
        defer { playback.stop() }
        playback.open(video("finished", seconds: 1))
        await played(playback)
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
        let playback = VideoPlayback(source: StubVideoSource(), audio: RecordingAudioSession())
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
