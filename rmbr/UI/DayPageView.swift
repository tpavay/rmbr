import SwiftUI

/// The first screen the day owns, before anything is scrolled.
private let heroHeight: CGFloat = 452

/// What a thumbnail on the rail is fetched at.
///
/// The preheat and the cell ask for this same value, because a different size is a
/// different cache key and the preheated copy would then be decoded for nobody.
private let dayGridTargetSize = CGSize(width: 600, height: 600)

/// The hero title fades as the glass bar takes over, so the date is never printed twice.
private func heroTitleOpacity(atScrollOffset offset: CGFloat) -> Double {
    let start = heroHeight - 210
    let end = heroHeight - 130
    guard offset > start else { return 1 }
    guard offset < end else { return 0 }
    return 1 - Double((offset - start) / (end - start))
}

/// One day: a hero, then a rail of moments, then the figures.
///
/// The cover owns the first screen and hands its date to a glass bar as you scroll. The
/// chronology is a true vertical rail with one bead per moment. The layout is settled;
/// what it must get right is that nothing on it is invented and nothing available is
/// hidden.
struct DayPageView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ThumbnailStore.self) private var thumbnails
    @Environment(\.dismiss) private var dismiss
    let date: LocalDate

    @State private var viewerMediaID: MediaID?
    /// The only thing the scroll writes into view state, and it changes twice a page.
    ///
    /// The parallax and the title fade read their own geometry through `visualEffect`
    /// instead: an offset held here would rebuild the whole page - every moment, every
    /// grid - on every frame of the scroll.
    @State private var barIsShowing = false

    var body: some View {
        content
            .background(Palette.deepInk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            // The index revision is the identity: it moves when the library is dropped and
            // again when a reconstruction commits, so a page left open across a narrowed
            // grant asks about the anchors of the library that exists now, and asks once
            // it exists rather than while there is nothing to ask about.
            .task(id: "\(model.committedRevision):\(date.description)") {
                await model.resolvePlaceNames(for: date)
            }
            // A viewer left open over a library that has just been narrowed is showing
            // photographs from a grant that no longer exists.
            .onChange(of: thumbnails.generation) { _, _ in viewerMediaID = nil }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasCommittedIndex {
            let day = model.day(for: date)
            ZStack(alignment: .top) {
                scroll(day)
                navigationBar
            }
            .onAppear { preheat(day) }
            .onDisappear { thumbnails.stopPreheating(window: preheatWindow) }
            .fullScreenCover(item: $viewerMediaID) { mediaID in
                MediaViewer(day: day, startAt: mediaID)
            }
        } else {
            LibraryStateNotice(
                heading: DayFormatting.heading(for: date, today: model.today),
                subject: "day",
                phase: model.phase
            )
        }
    }

    private func scroll(_ day: Day) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero(day)
                if !day.moments.isEmpty { chronology(day) } else { emptyStatement(day) }
                figures(day)
                attribution(day)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > heroHeight - 150
        } action: { _, showing in
            guard showing != barIsShowing else { return }
            barIsShowing = showing
            // The page changing state under the person's finger, once per crossing.
            Haptics.soft()
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func hero(_ day: Day) -> some View {
        let cover = day.media.coverMediaID.flatMap { day.media($0) }
        ZStack(alignment: .bottomLeading) {
            Group {
                if let cover {
                    MediaThumbnail(reference: cover, targetSize: CGSize(width: 1400, height: 1800))
                        // The parallax reads the hero's own position rather than a stored
                        // offset, so pulling the page down costs a redraw and not a
                        // rebuild of everything below it.
                        .visualEffect { content, proxy in
                            content.scaleEffect(
                                1 + max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY) / 900
                            )
                        }
                        // The photograph the day opens on is the one thing on this screen
                        // a tap does something with, so it says so.
                        .accessibilityElement()
                        .accessibilityAddTraits(.isImage)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(coverLabel(for: cover, in: day))
                        .accessibilityAction {
                            Haptics.rigid()
                            viewerMediaID = cover.id
                        }
                } else {
                    Rectangle().fill(Palette.smokedGlass)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()

            LinearGradient(
                colors: [
                    Palette.deepInk,
                    Palette.deepInk.opacity(0.18),
                    Palette.deepInk.opacity(0.55)
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: heroHeight)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(DayFormatting.heading(for: date, today: model.today))
                    .font(.editorial(32))
                    .foregroundStyle(date == model.today ? Palette.emberGlow : Palette.moonlightWhite)
                    .accessibilityAddTraits(.isHeader)
                let facts = DayFormatting.keyFacts(for: day)
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(.utility(12))
                        .foregroundStyle(Palette.moonlightWhite.opacity(0.72))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            // Given the hero's own height, so the fade reads the same top edge the
            // parallax does and an unresolved frame leaves the title showing.
            .frame(height: heroHeight, alignment: .bottomLeading)
            .visualEffect { content, proxy in
                content.opacity(
                    heroTitleOpacity(
                        atScrollOffset: -proxy.frame(in: .scrollView(axis: .vertical)).minY
                    )
                )
            }
        }
        .frame(height: heroHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if let cover {
                Haptics.rigid()
                viewerMediaID = cover.id
            }
        }
    }

    /// What the hero photograph is, for somebody who cannot see it.
    private func coverLabel(for cover: MediaReference, in day: Day) -> String {
        var parts: [String] = [cover.kind == .video ? "Video" : "Photo"]
        parts.append(DayFormatting.time(cover.captureTime, in: day.id.timeZone))
        if let moment = day.moments.first(where: { $0.allMediaIDs.contains(cover.id) }),
           let label = moment.place?.label.knownValue {
            parts.append(label.text)
        }
        if let duration = cover.duration { parts.append(DayFormatting.duration(duration)) }
        let eligible = day.media.eligibleMediaIDs
        if let ordinal = eligible.firstIndex(of: cover.id) {
            parts.append("\(ordinal + 1) of \(eligible.count)")
        }
        return parts.joined(separator: ", ")
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.soft()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.moonlightWhite)
                    .frame(width: 28, height: 28)
                    .background(Palette.smokedGlass, in: Circle())
            }
            .accessibilityLabel("Back")

            Text(DayFormatting.heading(for: date, today: model.today))
                .font(.editorial(15))
                .foregroundStyle(Palette.moonlightWhite)
                .opacity(barIsShowing ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(height: 96, alignment: .bottom)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(barIsShowing ? 1 : 0)
                .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .animation(.easeInOut(duration: 0.18), value: barIsShowing)
    }

    private var preheatWindow: String { "day-\(date.description)" }

    /// The page's inline captures are a bounded set, so PhotoKit is told about all of
    /// them at once rather than one grid cell at a time.
    private func preheat(_ day: Day) {
        var identifiers: [MediaID] = day.media.selectedMediaIDs
        for moment in day.moments {
            for mediaID in moment.displayedMediaIDs where !identifiers.contains(mediaID) {
                identifiers.append(mediaID)
            }
        }
        thumbnails.preheat(
            identifiers.compactMap { day.media($0) },
            targetSize: dayGridTargetSize,
            window: preheatWindow
        )
    }

    // MARK: - Chronology

    @ViewBuilder
    private func chronology(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(day.moments.enumerated()), id: \.element.id) { pair in
                MomentRow(
                    day: day,
                    moment: pair.element,
                    isFirst: pair.offset == 0,
                    onSelect: { mediaID in
                        Haptics.rigid()
                        viewerMediaID = mediaID
                    }
                )
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .topLeading) {
            // The rail itself: one hairline the beads hang off.
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
                .padding(.leading, 23)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
    }

    /// The only sentence rmbr prints about a day it can show nothing of (RQ-043).
    private func emptyStatement(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 38, height: 1)
            Text(DayFormatting.emptyDayStatement(for: day))
                .font(.utility(15))
                .foregroundStyle(Palette.dustyZinc)
            if let excluded = DayFormatting.exclusionSummary(day.media.exclusionCounts),
               day.media.eligibleMediaIDs.isEmpty {
                Text(excluded)
                    .font(.utility(10))
                    .textCase(.uppercase)
                    .kerning(1.3)
                    .foregroundStyle(Palette.dustyZinc)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Figures

    @ViewBuilder
    private func figures(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Day facts")
                .sectionLabelStyle()
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)

            // Every available value in the fixed order, and nothing for a value rmbr
            // cannot see. An unknown figure is omitted, never printed as zero, a dash
            // or a permission diagnosis (RQ-016, RQ-017).
            if let counts = day.media.rawCounts.knownValue {
                if counts.photoCount > 0 {
                    figureRow("Photographs", counts.photoCount.formatted())
                }
                if counts.videoCount > 0 {
                    figureRow("Videos", counts.videoCount.formatted())
                }
                if let placeCount = day.facts.placeCount.knownValue {
                    figureRow("Places", placeCount.formatted())
                }
                figureRow("Captures", counts.accessibleCaptureCount.formatted())
                if let excluded = DayFormatting.exclusionSummary(day.media.exclusionCounts) {
                    figureRow("Kept out", excluded)
                }
            } else {
                Text("rmbr can see only part of your library, so these counts are not complete.")
                    .font(.utility(13))
                    .foregroundStyle(Palette.dustyZinc)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
    }

    private func figureRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.utility(12))
                .foregroundStyle(Palette.dustyZinc)
            Spacer()
            Text(value)
                .font(.utility(12, weight: .medium))
                .foregroundStyle(Palette.moonlightWhite)
                .monospacedDigit()
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func attribution(_ day: Day) -> some View {
        // Geoapify's terms require this wherever the stored location data is reused.
        PlaceAttributionFooter(attributions: day.placeAttributions)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }
}

// MARK: - A moment on the rail

private struct MomentRow: View {
    let day: Day
    let moment: Moment
    let isFirst: Bool
    let onSelect: (MediaID) -> Void

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 3)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The bead. Ember for the moment that opened the day, quiet for the rest:
            // one ember per screen, and this is the screen's live edge.
            Circle()
                .fill(isFirst ? Palette.emberGlow : Palette.dustyZinc)
                .frame(width: 7, height: 7)
                .shadow(color: isFirst ? Palette.emberGlow.opacity(0.35) : .clear, radius: 4)
                .padding(.top, 6)
                .frame(width: 7)
                .padding(.trailing, 17)

            VStack(alignment: .leading, spacing: 3) {
                Text(DayFormatting.time(moment.chronology.start, in: day.id.timeZone))
                    .font(.utility(11.5, weight: .semibold))
                    .foregroundStyle(Palette.moonlightWhite)
                    .monospacedDigit()

                // A place appears only where the evidence supports one. A moment built
                // from photographs that carried no coordinates prints no place at all,
                // and never borrows one from the moment before it. A moment whose label
                // has not resolved yet prints nothing either: the day is readable now
                // and gains the name when it arrives, with no pending-state chrome
                // standing in for it (RQ-048, RQ-051).
                if let label = moment.place?.label.knownValue {
                    Text(label.text)
                        .font(.editorial(15))
                        .foregroundStyle(Palette.moonlightWhite)
                }

                if let claim = DayFormatting.durationClaim(moment.durationClaim, in: day.id.timeZone) {
                    Text(claim)
                        .font(.utility(10.5))
                        .foregroundStyle(Palette.dustyZinc)
                }

                let displayed = moment.displayedMediaIDs.compactMap { day.media($0) }
                if !displayed.isEmpty {
                    LazyVGrid(columns: Self.columns, spacing: 5) {
                        ForEach(displayed) { reference in
                            Button {
                                onSelect(reference.id)
                            } label: {
                                // The cell is square whatever the photograph is: the
                                // clear spacer sets the geometry and the image fills it,
                                // which an aspect ratio on the image itself does not do
                                // once the image has an intrinsic size of its own.
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        MediaThumbnail(
                                            reference: reference,
                                            targetSize: dayGridTargetSize
                                        )
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                accessibilityLabel(for: reference, in: day)
                            )
                        }
                    }
                    .padding(.top, 6)

                    // The day's display budget is capped at ten captures, so a day with
                    // many moments leaves later ones with no thumbnail at all.
                    let hidden = moment.allMediaIDs.count - moment.displayedMediaIDs.count
                    if hidden > 0 {
                        Text("\(hidden) more from this moment")
                            .font(.utility(10.5))
                            .foregroundStyle(Palette.dustyZinc)
                            .padding(.top, 6)
                    }
                } else if let composition = DayFormatting.mediaComposition(
                    of: moment.allMediaIDs.compactMap { day.media($0) }
                ) {
                    // A moment that showed nothing states what it holds; "more" would be
                    // more than nothing (RE-020).
                    Text(composition)
                        .font(.utility(10.5))
                        .foregroundStyle(Palette.dustyZinc)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 20)
    }

    private func accessibilityLabel(for media: MediaReference, in day: Day) -> String {
        var parts: [String] = [media.kind == .video ? "Video" : "Photo"]
        parts.append(DayFormatting.time(media.captureTime, in: day.id.timeZone))
        if let label = moment.place?.label.knownValue { parts.append(label.text) }
        if let duration = media.duration { parts.append(DayFormatting.duration(duration)) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The viewer

/// Full-screen paging across every eligible capture on the day, in chronological order.
///
/// Frames on a strip with black between them, arriving with a slight tilt: these were
/// shot, not stored. One rigid impact per frame, which is deliberately the densest
/// haptic in the app.
private struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let day: Day

    /// Seeded where the person opened it, rather than settled in `onAppear`: arriving on
    /// the frame they tapped is not the film advancing, and it must not sound like it.
    @State private var current: MediaID

    init(day: Day, startAt: MediaID) {
        self.day = day
        _current = State(initialValue: startAt)
    }

    var body: some View {
        let references = day.media.eligibleMediaIDs.compactMap { day.media($0) }
        let index = references.firstIndex { $0.id == current }
        ZStack(alignment: .topTrailing) {
            Palette.deepInk.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(references) { reference in
                    GeometryReader { proxy in
                        MediaThumbnail(
                            reference: reference,
                            targetSize: frameTarget(for: reference, fitting: proxy.size),
                            allowNetwork: true
                        )
                        .aspectRatio(reference.aspectRatio, contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        // The tilt is the film advance: each frame arrives with weight.
                        .rotationEffect(.degrees(reference.id == current ? 0 : -0.6))
                        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: current)
                    }
                    .padding(.horizontal, 8)
                    .tag(reference.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 2) {
                if let index {
                    Text(DayFormatting.time(references[index].captureTime, in: day.id.timeZone))
                        .font(.editorial(17))
                        .foregroundStyle(Palette.moonlightWhite)
                    Text(caption(for: references[index], at: index, of: references.count))
                        .font(.utility(11.5))
                        .foregroundStyle(Palette.moonlightWhite.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 22)
            .padding(.bottom, 60)

            Button {
                Haptics.soft()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.moonlightWhite)
                    .padding(12)
                    .background(Palette.smokedGlass, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        // The densest haptic in the app fires from here, so the engine is warmed before
        // the first swipe rather than on it.
        .onAppear { Haptics.prepare() }
        // One per frame: the shutter feeling the transition is named for.
        .onChange(of: current) { _, _ in Haptics.rigid() }
    }

    /// The pixels one frame actually draws.
    ///
    /// The frame is fitted into the screen, so this is the capture at that fitted size
    /// and no larger. A square target big enough for the tallest photograph asks for
    /// three times these pixels for a landscape one, and a single frame that size evicts
    /// every cover Life is holding.
    private func frameTarget(for reference: MediaReference, fitting size: CGSize) -> CGSize {
        let ratio = reference.aspectRatio > 0 ? reference.aspectRatio : 1
        let width = min(size.width, size.height * ratio)
        return CGSize(width: width * displayScale, height: width / ratio * displayScale)
    }

    private func caption(for reference: MediaReference, at index: Int, of total: Int) -> String {
        var parts: [String] = []
        if let moment = day.moments.first(where: { $0.allMediaIDs.contains(reference.id) }),
           let label = moment.place?.label.knownValue {
            parts.append(label.text)
        }
        parts.append("\(index + 1) of \(total)")
        return parts.joined(separator: " · ")
    }
}
