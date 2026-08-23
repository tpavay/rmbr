import AVFoundation
import SwiftUI
import UIKit

/// The layer the one player draws into.
///
/// `AVPlayerLayer` rather than `VideoPlayer` or an `AVPlayerViewController`: the strip is
/// a paged `TabView`, and `AVPlayerViewController` brings a scrubber, a tap-to-reveal
/// gesture and a transport bar that all claim horizontal drags across the whole frame -
/// which is the film advance's gesture. Its chrome is also a second visual language on a
/// screen that has one close button and one caption. What it would have given for free -
/// scrubbing, a position, AirPlay, Picture in Picture - is either rebuilt below in the
/// app's own language or deliberately not offered.
///
/// `resizeAspect` is the whole of the shape handling: the frame this sits in is already
/// the capture's aspect ratio, so a portrait video, a landscape one and a square one each
/// fill their frame exactly, the same way a still does. A capture whose stored pixel
/// dimensions disagree with the track's - a rotated recording, most often - letterboxes
/// inside the frame rather than stretching, because a video shown at the wrong shape is
/// not the video.
private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? PlayerLayerView else { return }
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        (view as? PlayerLayerView)?.playerLayer.player = nil
    }
}

// MARK: - What a video frame shows before, during and instead of playback

/// The centre of a video frame: the invitation, the wait, or the reason there is none.
///
/// Only one of the three is ever on screen, and none of them once the video is playable -
/// from that point the transport owns play and pause, and a second play triangle in the
/// middle of the frame would be one of them saying nothing.
struct VideoFrameControl: View {
    let phase: VideoPlayback.Phase
    let onPlay: () -> Void
    let onRetry: () -> Void

    var body: some View {
        switch phase {
        case .idle:
            playControl
        case .preparing(let progress):
            CloudFetchWaiting(progress: progress)
        case .ready:
            EmptyView()
        case .unavailable(let reason):
            if let sentence = reason.sentence {
                CloudFetchFailure(sentence: sentence, onRetry: onRetry)
            } else {
                playControl
            }
        }
    }

    private var playControl: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Palette.moonlightWhite)
                // Offset by the glyph's own optical imbalance, so the triangle looks
                // centred in the circle rather than measuring as centred in it.
                .offset(x: 2)
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play")
    }
}

// MARK: - The transport

/// Play, position, scrubbing and sound, in one row and in the app's own language.
///
/// It appears once the video is playable and stays for as long as it is, because a video
/// you cannot seek is half a feature and controls that hide themselves on a timer are a
/// video you cannot seek most of the time. Ember is on the played part of the track and
/// the playhead alone: that is the screen's live edge while a video is running, so
/// nothing else on it is allowed to be ember.
struct VideoTransport: View {
    @Bindable var playback: VideoPlayback

    var body: some View {
        HStack(spacing: 13) {
            Button {
                Haptics.soft()
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.moonlightWhite)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Text(DayFormatting.clock(playback.position))
                .videoClockStyle()

            VideoScrubber(playback: playback)

            Text(DayFormatting.clock(playback.length))
                .videoClockStyle()

            Button {
                Haptics.soft()
                playback.setMuted(!playback.isMuted)
            } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.moonlightWhite)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isMuted ? "Turn sound on" : "Turn sound off")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        // Smoked Glass as the system defines it - white at a low opacity over blur -
        // because these controls sit on the photograph itself, and a frame that fills
        // the screen can be any colour at all under them.
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Palette.smokedGlass)
                Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
        }
    }
}

/// The track, the played part of it, and the playhead the finger moves.
///
/// It lives in the viewer's chrome rather than on the frame, which is what keeps its drag
/// out of the paging gesture's way: a scrubber inside the strip would be a horizontal
/// drag competing with the horizontal drag that turns the page, and one of them would
/// lose unpredictably.
private struct VideoScrubber: View {
    @Bindable var playback: VideoPlayback

    private let trackHeight: CGFloat = 3
    private let knob: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob)
            let fraction = playback.length > 0 ? playback.position / playback.length : 0
            let played = CGFloat(min(max(fraction, 0), 1)) * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Palette.emberGlow)
                    .frame(width: played + knob / 2, height: trackHeight)
                Circle()
                    .fill(Palette.emberGlow)
                    .frame(width: knob, height: knob)
                    .shadow(color: Palette.emberGlow.opacity(0.4), radius: 4)
                    .offset(x: played)
            }
            .frame(height: knob)
            .frame(maxHeight: .infinity)
            // The thumb is bigger than the hairline it is moving, so the whole row is
            // the target rather than the three points that are drawn.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !playback.isScrubbing {
                            playback.beginScrubbing()
                            Haptics.soft()
                        }
                        let x = min(max(0, value.location.x - knob / 2), travel)
                        playback.scrub(to: Double(x / travel) * playback.length)
                    }
                    .onEnded { _ in playback.endScrubbing() }
            )
        }
        .frame(height: knob)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(
            "\(DayFormatting.clock(playback.position)) of \(DayFormatting.clock(playback.length))"
        )
        .accessibilityAdjustableAction { direction in
            let step = max(1, playback.length / 20)
            let target = direction == .increment
                ? playback.position + step
                : playback.position - step
            playback.scrub(to: target)
        }
    }
}

private extension View {
    /// A clock reading on the transport. Monospaced, so the row does not twitch as the
    /// seconds change under it.
    func videoClockStyle() -> some View {
        self
            .font(.utility(11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.moonlightWhite.opacity(0.85))
    }
}
