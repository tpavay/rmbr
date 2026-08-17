import SwiftUI

/// Every day in one calendar month.
///
/// This is where an old day that was not chosen to represent its month can still be
/// opened. Opening it composes that day and no other: the month never injects its
/// remaining days back into Life (RQ-069).
struct MonthView: View {
    @Environment(LibraryModel.self) private var model
    let month: Month

    var body: some View {
        let dates = model.dates(in: month)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let representative = model.representative(for: month) {
                    Text(reasonText(representative.reason))
                        .font(.utility(12))
                        .foregroundStyle(Palette.dustyZinc)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                ForEach(dates, id: \.description) { date in
                    NavigationLink {
                        DayPageView(date: date)
                    } label: {
                        MonthDayRow(date: date)
                    }
                    .buttonStyle(.plain)
                }
                PlaceAttributionFooter(attributions: attributions(for: dates))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            .padding(.vertical, 16)
        }
        .background(Palette.deepInk.ignoresSafeArea())
        .navigationTitle(DayFormatting.monthTitle(month))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The credit owed by the stored labels these rows print.
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
            return "This month is here because you favourited something that day."
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

private struct MonthDayRow: View {
    @Environment(LibraryModel.self) private var model
    let date: LocalDate

    var body: some View {
        // A row states what the archive survey already established about the day. The
        // day itself is composed when it is opened and not before, so listing a month
        // costs nothing that reading one of its days costs (RQ-069).
        let summary = model.summary(for: date)
        HStack(alignment: .center, spacing: 14) {
            Text("\(date.day)")
                .font(.editorial(20))
                .foregroundStyle(Palette.moonlightWhite)
                .frame(width: 34, alignment: .trailing)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline)
                    .font(.utility(14))
                    .foregroundStyle(summary.isEmpty ? Palette.dustyZinc : Palette.moonlightWhite)
                if let detail = summary.detail {
                    Text(detail)
                        .font(.utility(12))
                        .foregroundStyle(Palette.dustyZinc)
                }
            }

            Spacer(minLength: 0)

            if model.treatment(for: date) == .monthlyRepresentative {
                Circle()
                    .fill(Palette.emberGlow)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Chosen for this month")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
