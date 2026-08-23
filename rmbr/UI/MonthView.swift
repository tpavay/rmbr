import SwiftUI

/// A month as a mosaic of days, and the months on either side of it.
///
/// Everything at a glance, and honest about the days that hold nothing: an empty day is
/// an outlined square with its number, not an absence. This is the altitude above Life -
/// the same days, smaller.
///
/// Sideways is neighbours: one month a page, whole, never cut by the fold, and dragging
/// left walks backwards through a life, the same direction Life travels when a finger
/// goes up. Distance is not more of that gesture but a change of altitude, and the
/// calendar in the corner is how altitude changes here exactly as it does in Life. It is
/// a control rather than a light saying where you are.
///
/// A cell draws its day's cover, so the days whose cells the lazy grid has realised are
/// composed rather than only the day that is opened.
struct MonthView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let month: Month

    /// The month a page is settled on, which is the one the chrome names.
    @State private var settled: Month
    /// Which page the scroll is on, by month ordinal, so the position survives a redraw.
    @State private var position: Int?
    /// The day this month was last opened at, kept until a page moves. See `MonthCell`.
    @State private var returnedFrom: LocalDate?
    @State private var showingYears = false
    /// Written every frame the pager moves and read only by the title, so a scroll costs
    /// one small view's body rather than the whole screen's.
    @State private var metrics = PagerMetrics()

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    /// What the fixed chrome occupies, so a page's own scroll starts below it.
    private static let chromeHeight: CGFloat = 92
    /// How wide a wall is when the rubber band uncovers it.
    private static let wallWidth: CGFloat = 108

    init(month: Month) {
        self.month = month
        _settled = State(initialValue: month)
        _position = State(initialValue: month.ordinal)
    }

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
            ZStack {
                pager
                    .scaleEffect(showingYears ? 0.34 : 1)
                    .opacity(showingYears ? 0 : 1)
                    .allowsHitTesting(!showingYears)

                if showingYears {
                    YearsView(current: settled, onPick: drop(to:)) {
                        showingYears = false
                    }
                    // Contracting into the years and growing back out of them is the same
                    // zoom continuum the day page rides, one altitude higher.
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
                }
            }
            .animation(.rmbr, value: showingYears)
        } else {
            LibraryStateNotice(
                heading: DayFormatting.monthTitle(month),
                subject: "month",
                phase: model.phase
            )
        }
    }

    // MARK: - Sideways

    private var months: [Month] { model.browsableMonths }

    private var pager: some View {
        ZStack(alignment: .top) {
            walls
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(months, id: \.ordinal) { month in
                        page(for: month)
                            .containerRelativeFrame(.horizontal)
                            .id(month.ordinal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $position)
            .onScrollGeometryChange(for: CGSize.self) { geometry in
                CGSize(width: geometry.contentOffset.x, height: geometry.containerSize.width)
            } action: { _, latest in
                metrics.offset = latest.width
                metrics.pageWidth = max(latest.height, 1)
            }
            .onChange(of: position) { _, latest in
                guard let latest, let month = months.first(where: { $0.ordinal == latest }) else {
                    return
                }
                settled = month
                // The white ring is a mark on the month you were reading, so moving off it
                // is what clears it rather than a timer or the next tap.
                if returnedFrom?.month0 != month { returnedFrom = nil }
            }
            header
        }
    }

    private func page(for month: Month) -> some View {
        let dates = model.calendarDates(in: month)
        let withCaptures = model.datesWithCaptures(in: month)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
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
            .padding(.top, Self.chromeHeight)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        // The wall behind the pager may only be uncovered by the rubber band, so a page
        // carries its own ground rather than letting one show through mid-scroll.
        .background(Palette.deepInk)
    }

    /// What is at the two ends of a life, read by pulling past them.
    ///
    /// Neither is a page: paging onto them would make a wall somewhere you can stand.
    /// They sit behind the mosaic and the rubber band is what uncovers them, so the
    /// gesture that finds the end is the one that explains it.
    private var walls: some View {
        HStack(spacing: 0) {
            wall(
                heading: "Nothing after today",
                detail: "rmbr does not draw a day that has not happened."
            )
            Spacer(minLength: 0)
            wall(
                heading: "First photograph",
                detail: firstPhotographDate
            )
        }
        .padding(.top, Self.chromeHeight)
        .padding(.bottom, 32)
        .accessibilityHidden(true)
    }

    /// The date itself rather than a sentence about it: a life starts on a day, and the
    /// wall is narrow enough that the day is the only thing worth saying.
    private var firstPhotographDate: String {
        guard let earliest = model.earliestIndexedDate else {
            return "Nothing indexed yet."
        }
        return DayFormatting.heading(for: earliest, today: model.today)
    }

    private func wall(heading: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Palette.moonlightWhite.opacity(0.14))
                .frame(width: 18, height: 1)
            Text(heading)
                .font(.editorial(14))
                .foregroundStyle(Palette.dustyZinc)
            Text(detail)
                .font(.utility(10))
                .foregroundStyle(Palette.dustyZinc.opacity(0.7))
        }
        .frame(width: Self.wallWidth, alignment: .leading)
        .padding(.horizontal, 14)
    }

    // MARK: - Chrome

    private var header: some View {
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

                MonthTitle(metrics: metrics, months: months)

                Spacer(minLength: 0)

                // The calendar means one thing on every screen: up one altitude. In Life
                // it lifts you from days to a month; here it lifts you from a month to the
                // years. It stays dusty zinc because today's square is already the one
                // ember thing on this screen, and two would make one of them wrong.
                Button {
                    Haptics.soft()
                    showingYears = true
                } label: {
                    CalendarGlyph(isActive: false)
                        .frame(width: 44, height: 44, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse by year")
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 4)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                colors: [Palette.deepInk, Palette.deepInk, Palette.deepInk.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Altitude

    /// Comes back down onto the month a tile was touched, without walking the pages
    /// between: the point of the years is that distance costs a tap rather than a flick.
    private func drop(to month: Month) {
        var chosen = month
        if let newest = months.first, chosen > newest { chosen = newest }
        if let oldest = months.last, chosen < oldest { chosen = oldest }
        position = chosen.ordinal
        settled = chosen
        returnedFrom = nil
        showingYears = false
    }

    // MARK: - Cells

    private func cell(for date: LocalDate, hasCaptures: Bool) -> some View {
        NavigationLink {
            DayPageView(date: date)
        } label: {
            MonthCell(
                date: date,
                hasCaptures: hasCaptures,
                isToday: date == model.today,
                isReturn: date == returnedFrom
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            Haptics.soft()
            returnedFrom = date
        })
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

/// Where the pager is, between the two months it is between.
///
/// A scroll reports its offset every frame, and a title that reads it directly would make
/// every one of those frames rebuild the mosaic underneath. Kept here, only the title
/// observes it.
@MainActor
@Observable
final class PagerMetrics {
    var offset: CGFloat = 0
    var pageWidth: CGFloat = 1

    /// Which page, fractionally: 2.5 is halfway between the third month and the fourth.
    var progress: CGFloat { offset / pageWidth }
}

/// The month's name, sliding and crossfading with the page that carries it.
///
/// It travels a third of the page's distance. Moving with the mosaic rather than cutting
/// on arrival is what makes the two read as one object; moving slower than it is what
/// keeps the chrome chrome.
private struct MonthTitle: View {
    let metrics: PagerMetrics
    let months: [Month]

    var body: some View {
        let progress = metrics.progress
        let leading = Int(progress.rounded(.down))
        let fraction = min(max(progress - CGFloat(leading), 0), 1)
        let travel = metrics.pageWidth / 3

        ZStack(alignment: .leading) {
            label(at: leading)
                .opacity(Double(1 - fraction))
                .offset(x: -fraction * travel)
            label(at: leading + 1)
                .opacity(Double(fraction))
                .offset(x: (1 - fraction) * travel)
        }
        .frame(height: 32, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(
            months.indices.contains(nearest) ? DayFormatting.monthTitle(months[nearest]) : ""
        )
    }

    /// Whichever of the two months the page is closer to, which is the one being named.
    private var nearest: Int { Int(metrics.progress.rounded()) }

    @ViewBuilder
    private func label(at index: Int) -> some View {
        if months.indices.contains(index) {
            Text(DayFormatting.monthTitle(months[index]))
                .font(.editorial(22))
                .foregroundStyle(Palette.moonlightWhite)
                .fixedSize()
        }
    }
}

private struct MonthCell: View {
    @Environment(LibraryModel.self) private var model
    let date: LocalDate
    let hasCaptures: Bool
    let isToday: Bool
    /// The day this month was last opened at, so coming back lands somewhere findable.
    let isReturn: Bool

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
            // Today is ember and the day you came back from is moonlight, and where they
            // are the same day today wins: ember is the live edge, and a second ember mark
            // on one screen would make one of them wrong.
            if isToday {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.emberGlow, lineWidth: 1.5)
            } else if isReturn {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.moonlightWhite.opacity(0.9), lineWidth: 1.5)
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
