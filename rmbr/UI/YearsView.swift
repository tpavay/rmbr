import SwiftUI

/// The altitude above the mosaic: a life as twelve mosaics a year.
///
/// The mosaic can only ever hold one month, so reaching a month seven years back would be
/// eighty-four pages of it. This is the long-range gear, and it is reached the same way
/// every altitude in rmbr is reached - the calendar, which always means up one.
///
/// A tile is too small for a photograph, so it draws the only thing that survives at this
/// size: which days hold something. That is what makes a year legible as a shape rather
/// than as a number, and it is why the plate is worth a surface of its own.
struct YearsView: View {
    @Environment(LibraryModel.self) private var model
    /// The month the mosaic is standing on, so the plate opens on it rather than at a end.
    let current: Month
    let onPick: (Month) -> Void
    let onClose: () -> Void

    /// Twelve tiles and eleven gaps inside the page's own margins.
    private static let margin: CGFloat = 19
    private static let tileGap: CGFloat = 6
    private static let dotGap: CGFloat = 1

    var body: some View {
        ZStack(alignment: .top) {
            Palette.deepInk.ignoresSafeArea()
            rows
            header
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    Haptics.soft()
                    onClose()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.moonlightWhite)
                        .frame(width: 28, height: 28)
                        .background(Palette.smokedGlass, in: Circle())
                }
                .accessibilityLabel("Back down to the month")

                Text("Every year")
                    .font(.editorial(22))
                    .foregroundStyle(Palette.moonlightWhite)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

                Text(subtitle)
                    .sectionLabelStyle()
            }
            .padding(.horizontal, 20)

            monthKey
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background {
            LinearGradient(
                colors: [Palette.deepInk, Palette.deepInk, Palette.deepInk.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    private var subtitle: String {
        let years = model.browsableYears.count
        let days = model.browsableMonths.reduce(0) { $0 + model.density(for: $1).count }
        guard days > 0 else { return DayFormatting.count(years, singular: "year", plural: "years") }
        return DayFormatting.count(years, singular: "year", plural: "years")
            + " · " + DayFormatting.count(days, singular: "day", plural: "days")
    }

    /// One initial per column, so a tile's position in the row says which month it is.
    private var monthKey: some View {
        GeometryReader { proxy in
            let width = tileWidth(in: proxy.size.width)
            HStack(spacing: Self.tileGap) {
                ForEach(1...12, id: \.self) { month in
                    Text(DayFormatting.monthInitial(month))
                        .font(.utility(8.5, weight: .medium))
                        .foregroundStyle(Palette.dustyZinc)
                        .frame(width: width)
                }
            }
            .padding(.horizontal, Self.margin)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    // MARK: - The years

    private var rows: some View {
        GeometryReader { proxy in
            let width = tileWidth(in: proxy.size.width)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.browsableYears, id: \.self) { year in
                        YearRow(
                            year: year,
                            tileWidth: width,
                            tileGap: Self.tileGap,
                            dotGap: Self.dotGap,
                            current: current,
                            onPick: onPick
                        )
                        .padding(.horizontal, Self.margin)
                    }
                }
                .padding(.top, 96)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            // The plate opens on the month it was climbed from rather than at the top, so
            // the climb never loses your place in a life that is seventeen years long.
            .defaultScrollAnchor(anchor(for: current))
        }
    }

    private func tileWidth(in total: CGFloat) -> CGFloat {
        let usable = max(total - Self.margin * 2 - Self.tileGap * 11, 12)
        return usable / 12
    }

    /// Where the scroll should open so the month climbed from is on screen.
    private func anchor(for month: Month) -> UnitPoint {
        let years = model.browsableYears
        guard let position = years.firstIndex(of: month.year), years.count > 1 else { return .top }
        return UnitPoint(x: 0, y: CGFloat(position) / CGFloat(years.count - 1))
    }
}

/// One year, as twelve month tiles.
///
/// The dots are drawn rather than laid out: a life is a couple of hundred months and six
/// thousand days, and one canvas a row keeps that a drawing cost rather than a view-tree
/// cost. The tap targets and the labels are real buttons over the top, so a drawing does
/// not cost this screen its hit-testing or its VoiceOver.
private struct YearRow: View {
    @Environment(LibraryModel.self) private var model
    let year: Int
    let tileWidth: CGFloat
    let tileGap: CGFloat
    let dotGap: CGFloat
    let current: Month
    let onPick: (Month) -> Void

    private var today: LocalDate { model.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(year))
                .font(.editorial(15))
                .foregroundStyle(year == today.year ? Palette.emberGlow : Palette.dustyZinc)
                .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context) }
                    .frame(height: tileHeight)
                    .allowsHitTesting(false)

                HStack(spacing: tileGap) {
                    ForEach(1...12, id: \.self) { month in
                        tile(Month(year: year, month: month))
                    }
                }
            }
        }
    }

    private var dotSize: CGFloat { max((tileWidth - dotGap * 3) / 4, 1) }
    private var tileHeight: CGFloat { dotSize * 8 + dotGap * 7 }

    private func tile(_ month: Month) -> some View {
        let browsable = model.isBrowsable(month)
        return Button {
            Haptics.soft()
            onPick(month)
        } label: {
            Color.clear
                .frame(width: tileWidth, height: tileHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!browsable)
        .accessibilityLabel(label(for: month, browsable: browsable))
        .accessibilityAddTraits(month == current ? [.isSelected] : [])
    }

    private func label(for month: Month, browsable: Bool) -> String {
        guard browsable else { return "\(DayFormatting.monthTitle(month)), outside your library" }
        let count = model.density(for: month).count
        guard count > 0 else { return "\(DayFormatting.monthTitle(month)), nothing recorded" }
        return "\(DayFormatting.monthTitle(month)), "
            + DayFormatting.count(count, singular: "day", plural: "days")
    }

    /// A tile is a month's calendar at four columns, the mosaic's own shape made small.
    private func draw(in context: inout GraphicsContext) {
        for column in 0..<12 {
            let month = Month(year: year, month: column + 1)
            let originX = CGFloat(column) * (tileWidth + tileGap)
            guard model.isBrowsable(month) else {
                drawGhost(in: &context, originX: originX)
                continue
            }
            let density = model.density(for: month)
            let isCurrent = month == current
            if isCurrent {
                let inset = dotGap
                context.fill(
                    Path(
                        roundedRect: CGRect(
                            x: originX - inset,
                            y: -inset,
                            width: tileWidth + inset * 2,
                            height: tileHeight + inset * 2
                        ),
                        cornerRadius: 3
                    ),
                    with: .color(Palette.emberGlow.opacity(0.16))
                )
            }
            for day in 1...density.days {
                let rect = dotRect(day: day, originX: originX)
                let isToday = LocalDate(year: year, month: column + 1, day: day) == today
                let colour: Color = if isToday {
                    Palette.emberGlow
                } else if density.hasCaptures(on: day) {
                    Palette.moonlightWhite.opacity(isCurrent ? 0.9 : 0.55)
                } else {
                    Color.white.opacity(0.06)
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(colour))
            }
        }
    }

    /// A month outside the library keeps its place so a year is always twelve wide.
    private func drawGhost(in context: inout GraphicsContext, originX: CGFloat) {
        context.stroke(
            Path(
                roundedRect: CGRect(x: originX, y: 0, width: tileWidth, height: tileHeight),
                cornerRadius: 2
            ),
            with: .color(Color.white.opacity(0.04)),
            lineWidth: 1
        )
    }

    private func dotRect(day: Int, originX: CGFloat) -> CGRect {
        let column = (day - 1) % 4
        let row = (day - 1) / 4
        return CGRect(
            x: originX + CGFloat(column) * (dotSize + dotGap),
            y: CGFloat(row) * (dotSize + dotGap),
            width: dotSize,
            height: dotSize
        )
    }
}
