import SwiftUI

/// Why an original iCloud holds never became something rmbr could show.
///
/// Each case is a different true sentence. "Something went wrong" is not one of them: a
/// capture sitting in iCloud that rmbr could not fetch is a different fact from one on
/// this phone that will not open, and the person can act on the first.
///
/// One type for both the video path and the pixel path on purpose. A video that will not
/// play and a photograph that will not draw are the same three facts about the same
/// library, and telling them in two vocabularies would be rmbr saying the same thing
/// twice in different words.
enum CaptureUnavailability: Error, Sendable, Hashable {
    /// The person swiped away, or the request was superseded. Nothing to say.
    case cancelled
    /// The original lives in iCloud and the fetch did not finish.
    case notFetched
    /// It is here and it will not open.
    case unreadable

    /// What a surface prints, in the noun the capture actually is. One sentence, stated
    /// rather than apologised for.
    func sentence(for kind: MediaKind) -> String? {
        switch self {
        case .cancelled:
            return nil
        case .notFetched:
            return "This \(Self.noun(kind)) is stored in iCloud and rmbr could not finish"
                + " downloading it."
        case .unreadable:
            return "rmbr could not open this \(Self.noun(kind))."
        }
    }

    /// What the viewer prints for a video, which is the only thing it plays.
    var sentence: String? { sentence(for: .video) }

    private static func noun(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: return "photo"
        case .livePhoto: return "Live Photo"
        case .video: return "video"
        }
    }
}

// MARK: - What each surface does about an offloaded original

/// What a surface does about an original iCloud has taken off the device.
///
/// PhotoKit answers a request that refuses the network with the degraded thumbnail it
/// happens to hold locally and nothing more, so this is the difference between a capture
/// that can arrive at full quality and one that is blurry for ever. It is deliberately a
/// decision per surface rather than one default for the whole app: a flick through a
/// year of covers must not become a year of full-size downloads, and a photograph filling
/// the screen must not stay a thumbnail.
///
/// Fetching is only half of it. Once a surface can go to iCloud it can also be slow or
/// fail, and a blurry frame with nothing said about it is not a resting state anybody
/// can read - which is why the cases that spend the network also say so.
enum CloudFetchPolicy: Equatable, Sendable {
    /// Never spends the network. The degraded local thumbnail is all this surface shows.
    case refuse
    /// Fetches, and says nothing, because something else on the same frame is already
    /// saying it.
    case fetchSilently
    /// Fetches, and states the wait and the failure, without a control of its own.
    case fetchAndState
    /// Fetches, states both, and offers to ask again.
    case fetchStateAndRetry

    var allowsNetwork: Bool { self != .refuse }
    var statesFetch: Bool { self == .fetchAndState || self == .fetchStateAndRetry }
    var offersRetry: Bool { self == .fetchStateAndRetry }
}

/// The decision taken for each surface that draws captures, in one place.
///
/// Named rather than spelled out at the call sites so the audit behind them is a fact of
/// the code: what each surface does about iCloud is readable here in one screen, and a
/// change to one of them is a change to a documented decision rather than a stray flag.
extension CloudFetchPolicy {
    /// The day page's hero: one photograph, full bleed, on a page the person navigated
    /// to deliberately. Exactly the place worth a download, and the place where a
    /// permanent blur is worst - the further back the day, the more likely iCloud has
    /// taken the original away.
    ///
    /// It states the wait and the failure but offers no control, because the hero's whole
    /// surface is already the tap target that opens the viewer: a button in the middle of
    /// it would take that tap, and the hero is flattened into a single accessibility
    /// element, where a control inside it cannot be reached at all. The viewer it opens
    /// asks again for the same capture, and offers the retry there.
    static let dayHero = CloudFetchPolicy.fetchAndState

    /// The full-screen viewer: the capture is the screen, and the person is looking at
    /// this one. Both the wait and the retry belong here.
    static let viewerStill = CloudFetchPolicy.fetchStateAndRetry

    /// The still standing in for a video in the viewer, which fetches for the same reason
    /// the still beside it does but says nothing: `VideoFrameControl` is already drawing
    /// this frame's wait and this frame's failure, and two rings on one frame is one of
    /// them saying nothing.
    static let viewerVideoFrame = CloudFetchPolicy.fetchSilently

    /// A Life day card. Full width, but one of hundreds in an unbounded scroll: a flick
    /// through a year would ask iCloud for every cover it passed, which is a great deal
    /// of somebody's data spent on photographs they are scrolling past rather than
    /// looking at. Tapping the day is the deliberate act, and the hero on the other side
    /// of that tap is the same photograph, larger, fetched properly.
    static let lifeCard = CloudFetchPolicy.refuse

    /// A month mosaic cell: a postage stamp at 300 by 300, thirty-odd to a screen. A
    /// full-size download per cell is a month of originals fetched to draw a grid.
    static let monthCell = CloudFetchPolicy.refuse

    /// A thumbnail on the day page's moment rail. Small, many, and one tap away from the
    /// viewer, which fetches whichever of them the person actually opens.
    static let dayGridCell = CloudFetchPolicy.refuse
}

// MARK: - Where a capture's pixels have got to

/// The three facts a fetch can be in the middle of.
///
/// The same three `VideoPlayback.Phase` carries, minus the idle case a still does not
/// have: a photograph is never waiting to be asked for.
enum CloudFetchPhase: Equatable {
    /// Asked for, not here yet. `progress` is the iCloud download when PhotoKit reports
    /// one, and nil while it is merely producing something already on the device.
    case preparing(progress: Double?)
    /// The full-quality pixels arrived.
    case ready
    case unavailable(CaptureUnavailability)
}

/// The phase a capture is in, and whether it is worth saying out loud yet.
///
/// A value type rather than an observable object because `MediaThumbnail` is drawn once
/// per cell in a grid, and a state machine costing an allocation per postage stamp is a
/// scroll. Keeping the transitions here rather than inside the view's task is what makes
/// them assertable without a screen.
struct CloudFetchState: Equatable {
    private(set) var phase: CloudFetchPhase = .preparing(progress: nil)
    /// Whether the wait has lasted, or declared itself, long enough to be worth stating.
    private(set) var waitIsWorthStating = false

    /// What the surface draws, and nothing at all while there is nothing to say.
    ///
    /// An original already on the device is decoded in a frame or two, and a ring that
    /// appears and vanishes on every page is chrome pretending something happened. So a
    /// wait is silent until either it has gone on long enough to be a wait or PhotoKit
    /// has admitted it is downloading. A failure is never silent: it is the answer.
    var statement: CloudFetchPhase? {
        switch phase {
        case .ready:
            return nil
        case .preparing:
            return waitIsWorthStating ? phase : nil
        case .unavailable(.cancelled):
            // Nobody is owed a sentence about a request they walked away from.
            return nil
        case .unavailable:
            return phase
        }
    }

    mutating func apply(_ update: ThumbnailUpdate) {
        switch update {
        case .fetching(let fraction):
            guard case .preparing = phase else { return }
            // PhotoKit admitting to a download is evidence on its own, so there is no
            // grace period left to wait out before repeating what it has just said.
            waitIsWorthStating = true
            phase = .preparing(progress: fraction)
        case .image(_, let isDegraded):
            // The degraded pass is the placeholder PhotoKit holds locally rather than the
            // pixels that were asked for, so the wait is still on.
            guard !isDegraded else { return }
            phase = .ready
        case .unavailable(let reason):
            phase = .unavailable(reason)
        }
    }

    /// The wait has gone on long enough to be worth a word.
    mutating func waitBecameWorthStating() {
        guard case .preparing = phase else { return }
        waitIsWorthStating = true
    }
}

// MARK: - What a capture says while it is waiting, and instead of arriving

/// The wait, and the reason there is none, in the one vocabulary rmbr has for them.
///
/// Drawn over whatever the surface already has - the degraded thumbnail, most often,
/// which is the blur these two sentences exist to account for.
struct CloudFetchNotice: View {
    let phase: CloudFetchPhase
    /// What the capture is, so the sentence uses its noun.
    let kind: MediaKind
    /// Absent where the surface's own frame is already a tap target, and the control
    /// would take the tap.
    var onRetry: (() -> Void)?

    var body: some View {
        switch phase {
        case .preparing(let progress):
            CloudFetchWaiting(progress: progress)
        case .ready:
            EmptyView()
        case .unavailable(let reason):
            if let sentence = reason.sentence(for: kind) {
                CloudFetchFailure(sentence: sentence, onRetry: onRetry)
            }
        }
    }
}

/// Something was asked for and has not arrived.
///
/// A determinate ring whenever PhotoKit reports a download, because "42 per cent of the
/// way through fetching this from iCloud" is a fact worth stating and an indeterminate
/// spinner would be rmbr pretending not to know it.
struct CloudFetchWaiting: View {
    let progress: Double?

    @State private var spin = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress.map { min(max($0, 0.02), 1) } ?? 0.16)
                    .stroke(Palette.emberGlow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(progress == nil ? (spin ? 360 : 0) : -90))
                    .animation(
                        progress == nil
                            ? .linear(duration: 0.85).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.25),
                        value: progress == nil ? spin : (progress ?? 0) > 0
                    )
            }
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())

            if let progress {
                Text("Fetching from iCloud · \(Int((progress * 100).rounded()))%")
                    .font(.utility(11.5))
                    .foregroundStyle(Palette.moonlightWhite.opacity(0.85))
                    .monospacedDigit()
                    .shadow(radius: 4)
            }
        }
        .onAppear { spin = true }
        .accessibilityElement()
        .accessibilityLabel(
            progress.map { "Fetching from iCloud, \(Int(($0 * 100).rounded())) per cent" }
                ?? "Fetching"
        )
    }
}

/// It is not coming, and the sentence says which kind of not.
struct CloudFetchFailure: View {
    let sentence: String
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text(sentence)
                .font(.utility(13.5))
                .foregroundStyle(Palette.moonlightWhite.opacity(0.9))
                .multilineTextAlignment(.center)
                .shadow(radius: 5)
            if let onRetry {
                Button(action: onRetry) {
                    Text("Try again")
                        .font(.utility(12.5, weight: .semibold))
                        .foregroundStyle(Palette.emberGlow)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: 320)
    }
}
