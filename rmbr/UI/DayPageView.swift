import SwiftUI

/// One day, read top to bottom: Composition, Chronology, Figures.
///
/// Three sections of one vertical scroll, never tabs or cards to swipe between. The
/// layout is rough on purpose; what it must get right is that nothing on it is invented
/// and nothing available is hidden.
struct DayPageView: View {
    @Environment(LibraryModel.self) private var model
    let date: LocalDate

    @State private var viewerMediaID: MediaID?

    var body: some View {
        let day = model.day(for: date)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                composition(day)
                if !day.moments.isEmpty { chronology(day) }
                figures(day)
                attribution(day)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 52)
            .padding(.bottom, 32)
        }
        .background(Palette.deepInk.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: date.description) {
            await model.resolvePlaceNames(for: date)
        }
        .sheet(item: $viewerMediaID) { mediaID in
            MediaViewer(day: day, startAt: mediaID)
        }
    }

    // MARK: - Composition

    @ViewBuilder
    private func composition(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(DayFormatting.heading(for: date, today: model.today))
                .font(.editorial(32))
                .foregroundStyle(date == model.today ? Palette.emberGlow : Palette.moonlightWhite)
                .accessibilityAddTraits(.isHeader)

            let featured = Array(day.media.selectedMediaIDs.prefix(3))
                .compactMap { day.media($0) }

            if let dominant = featured.first {
                Button {
                    viewerMediaID = dominant.id
                } label: {
                    MediaThumbnail(reference: dominant, targetSize: CGSize(width: 1200, height: 1500))
                        .aspectRatio(4.0 / 5.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: dominant, in: day, ordinal: 1))
            }

            if featured.count > 1 {
                HStack(spacing: 12) {
                    ForEach(Array(featured.dropFirst().enumerated()), id: \.element.id) { pair in
                        Button {
                            viewerMediaID = pair.element.id
                        } label: {
                            MediaThumbnail(
                                reference: pair.element,
                                targetSize: CGSize(width: 600, height: 600)
                            )
                            // Supporting assets keep their own portrait or landscape
                            // shape rather than being forced into one crop.
                            .frame(
                                width: 130 * min(max(pair.element.aspectRatio, 0.62), 1.6),
                                height: 130
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            accessibilityLabel(for: pair.element, in: day, ordinal: pair.offset + 2)
                        )
                    }
                    Spacer(minLength: 0)
                }
            }

            let facts = DayFormatting.keyFacts(for: day)
            if facts.isEmpty && day.moments.isEmpty {
                // The only sentence rmbr ever prints about an empty day. It says what
                // rmbr has, not what the person did (RQ-043).
                Text("rmbr has nothing recorded for this day.")
                    .font(.utility(15))
                    .foregroundStyle(Palette.dustyZinc)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(facts, id: \.self) { fact in
                        Text(fact)
                            .font(.utility(15))
                            .foregroundStyle(Palette.moonlightWhite)
                    }
                }
            }
        }
    }

    // MARK: - Chronology

    @ViewBuilder
    private func chronology(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Timeline")
                .sectionLabelStyle()
                .accessibilityAddTraits(.isHeader)

            ForEach(day.moments) { moment in
                MomentRow(day: day, moment: moment) { mediaID in
                    viewerMediaID = mediaID
                }
            }
        }
    }

    // MARK: - Figures

    @ViewBuilder
    private func figures(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Day facts")
                .sectionLabelStyle()
                .accessibilityAddTraits(.isHeader)

            // Every available value in the fixed order, and nothing for a value rmbr
            // cannot see. An unknown figure is omitted, never printed as zero, a dash
            // or a permission diagnosis (RQ-016, RQ-017).
            if let counts = day.media.rawCounts.knownValue {
                if counts.photoCount > 0 {
                    figureRow("Photos", counts.photoCount.formatted())
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
            }
        }
    }

    private func figureRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.utility(13))
                .foregroundStyle(Palette.dustyZinc)
            Spacer()
            Text(value)
                .font(.utility(13, weight: .medium))
                .foregroundStyle(Palette.moonlightWhite)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func attribution(_ day: Day) -> some View {
        let attributions = day.placeAttributions
        if !attributions.isEmpty {
            // Geoapify's terms require this wherever the stored location data is reused.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(attributions, id: \.self) { line in
                    Text("Place names \(line), via Geoapify")
                        .font(.utility(11))
                        .foregroundStyle(Palette.dustyZinc)
                }
            }
            .padding(.top, 8)
        }
    }

    private func accessibilityLabel(for media: MediaReference, in day: Day, ordinal: Int) -> String {
        var parts: [String] = [media.kind == .video ? "Video" : "Photo"]
        parts.append(DayFormatting.time(media.captureTime, in: day.id.timeZone))
        if let moment = day.moments.first(where: { $0.allMediaIDs.contains(media.id) }),
           let label = moment.place?.label.knownValue {
            parts.append(label.text)
        }
        if let duration = media.duration {
            parts.append(DayFormatting.duration(duration))
        }
        parts.append("\(ordinal) of \(day.media.selectedMediaIDs.count)")
        return parts.joined(separator: ", ")
    }
}

private struct MomentRow: View {
    @Environment(LibraryModel.self) private var model
    let day: Day
    let moment: Moment
    let onSelect: (MediaID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DayFormatting.time(moment.chronology.start, in: day.id.timeZone))
                    .font(.utility(13, weight: .semibold))
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
                        .font(.utility(13))
                        .foregroundStyle(Palette.moonlightWhite)
                }
                Spacer(minLength: 0)
            }

            if let claim = DayFormatting.durationClaim(moment.durationClaim, in: day.id.timeZone) {
                Text(claim)
                    .font(.utility(12))
                    .foregroundStyle(Palette.dustyZinc)
            }

            let displayed = moment.displayedMediaIDs.compactMap { day.media($0) }
            if !displayed.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(displayed) { reference in
                        Button {
                            onSelect(reference.id)
                        } label: {
                            MediaThumbnail(
                                reference: reference,
                                targetSize: CGSize(width: 600, height: 600)
                            )
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            let hidden = moment.allMediaIDs.count - moment.displayedMediaIDs.count
            if hidden > 0 {
                Text("\(hidden) more from this moment")
                    .font(.utility(11))
                    .foregroundStyle(Palette.dustyZinc)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Full-screen paging across every eligible capture on the day, in chronological order.
private struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let day: Day
    let startAt: MediaID

    @State private var current: MediaID?

    var body: some View {
        let references = day.media.eligibleMediaIDs.compactMap { day.media($0) }
        ZStack(alignment: .topTrailing) {
            Palette.deepInk.ignoresSafeArea()
            TabView(selection: Binding(get: { current ?? startAt }, set: { current = $0 })) {
                ForEach(references) { reference in
                    VStack(spacing: 12) {
                        MediaThumbnail(
                            reference: reference,
                            targetSize: CGSize(width: 2000, height: 2000),
                            allowNetwork: true
                        )
                        .aspectRatio(reference.aspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        Text(DayFormatting.time(reference.captureTime, in: day.id.timeZone))
                            .font(.utility(13))
                            .foregroundStyle(Palette.dustyZinc)
                    }
                    .tag(reference.id)
                }
            }
            .tabViewStyle(.page)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Palette.moonlightWhite)
                    .padding(12)
                    .background(Palette.smokedGlass, in: Circle())
            }
            .padding(16)
        }
        .onAppear { if current == nil { current = startAt } }
    }
}
