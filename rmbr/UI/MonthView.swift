import SwiftUI

/// A month as a mosaic of days.
///
/// Everything at a glance, and honest about the days that hold nothing: an empty day is
/// an outlined square with its number, not an absence. This is the altitude above Life -
/// the same days, smaller - and the calendar in the corner glows to say you are inside
/// it (RQ-069: opening a month composes only the day you open).
struct MonthView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let month: Month
    /// The day the person came from, marked so they can find their way back to it.
    var highlighted: LocalDate?

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        content
            .background(Palette.deepInk.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        // Without a committed index every day in the month reads as absent, which would
        // print a month that held nothing rather than a month rmbr cannot describe yet.
        if model.hasCommittedIndex {
            let dates = model.calendarDates(in: month)
            let withCaptures = model.datesWithCaptures(in: month)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(daysWithCaptures: withCaptures.count)
                    LazyVGrid(columns: Self.columns, spacing: 6) {
                        ForEach(dates, id: \.description) { date in
                            cell(for: date, hasCaptures: withCaptures.contains(date))
                        }
                    }
                    .padding(.horizontal, 16)
                    if let representative = model.representative(for: month) {
                        Text(reasonText(representative.reason))
                            .font(.utility(12))
                            .foregroundStyle(Palette.dustyZinc)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                    }
                    PlaceAttributionFooter(attributions: attributions(for: dates))
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                .padding(.bottom, 32)
            }
        } else {
            LibraryStateNotice(
                heading: DayFormatting.monthTitle(month),
                subject: "month",
                phase: model.phase
            )
        }
    }

    private func header(daysWithCaptures: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .accessibilityLabel("Back to Life")

                Text(DayFormatting.monthTitle(month))
                    .font(.editorial(22))
                    .foregroundStyle(Palette.moonlightWhite)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)
                CalendarGlyph(isActive: true)
            }
            Text(subtitle(daysWithCaptures: daysWithCaptures))
                .sectionLabelStyle()
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private func subtitle(daysWithCaptures: Int) -> String {
        guard daysWithCaptures > 0 else { return "No photographs this month" }
        return DayFormatting.count(daysWithCaptures, singular: "day", plural: "days")
    }

    private func cell(for date: LocalDate, hasCaptures: Bool) -> some View {
        NavigationLink {
            DayPageView(date: date)
        } label: {
            MonthCell(
                date: date,
                hasCaptures: hasCaptures,
                isHighlighted: date == highlighted,
                isToday: date == model.today
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Haptics.soft() })
    }

    /// The credit owed by the stored labels these cells stand for.
    private func attributions(for dates: [LocalDate]) -> [String] {
        var lines: [String] = []
        var credits: Set<String> = []
        for date in dates {
            for line in model.summary(for: date).attributions
            where credits.insert(ResolvedPlaceLabel.creditKey(line)).inserted {
                lines.append(line)
            }
        }
        return lines
    }

    /// One reason code, expressed as a sentence, never a score.
    ///
    /// The signals count videos as readily as photographs, so the wording stays neutral
    /// about what a day held. Under limited access the cascade only ever compared the
    /// days rmbr was shown, so a comparison says so rather than stating a fact about the
    /// whole archive.
    private func reasonText(_ reason: RepresentativeReason) -> String {
        let sawEverything = model.access.isExhaustive
        switch reason {
        case .favoriteMedia:
            return "This month is here because you favorited something that day."
        case .archiveUniquePlace:
            return sawEverything
                ? "This month is here because that day is the only one at that place."
                : "This month is here because it is the only day rmbr can see at that place."
        case .greatestDistinctPlaceCount:
            return sawEverything
                ? "This month is here because that day has the most places."
                : "This month is here because that day has the most places rmbr can see."
        case .greatestMomentCount:
            return sawEverything
                ? "This month is here because that day has the most moments."
                : "This month is here because that day has the most moments rmbr can see."
        case .greatestEligibleMediaCount:
            // The cascade compared displayable media, not every capture: a day of
            // screenshots can hold more and still not win this tier.
            return sawEverything
                ? "This month is here because that day has the most media rmbr can show."
                : "This month is here because that day has the most media rmbr can show"
                    + " among the days it can see."
        case .nearestMonthMidpoint:
            return "This month is here because that day sits nearest its middle."
        }
    }
}

private struct MonthCell: View {
    @Environment(LibraryModel.self) private var model
    let date: LocalDate
    let hasCaptures: Bool
    let isHighlighted: Bool
    let isToday: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if hasCaptures, let reference = cover {
                MediaThumbnail(reference: reference, targetSize: CGSize(width: 300, height: 300))
                    .aspectRatio(1, contentMode: .fill)
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    }
            }
            Text("\(date.day)")
                .font(.utility(10, weight: .medium))
                .foregroundStyle(
                    hasCaptures ? Palette.moonlightWhite.opacity(0.92) : Palette.dustyZinc
                )
                .shadow(color: hasCaptures ? .black.opacity(0.6) : .clear, radius: 3, y: 1)
                .padding(.leading, 6)
                .padding(.top, 4)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isHighlighted || isToday {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.emberGlow, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(DayFormatting.heading(for: date, today: model.today)), "
            + (hasCaptures ? model.summary(for: date).headline : "nothing recorded")
        )
    }

    /// A cell composes its day the first time it scrolls into view.
    ///
    /// The grid is lazy, so a month costs the dozen or so cells that are actually on
    /// screen rather than all thirty-one, and a composed day costs well under a frame.
    /// The survey cannot supply this: it knows a day's counts and places but not which
    /// capture would represent it.
    private var cover: MediaReference? {
        let day = model.day(for: date)
        guard let coverID = day.media.coverMediaID else { return nil }
        return day.media(coverID)
    }
}
