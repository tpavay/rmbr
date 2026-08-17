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
            }
            .padding(.vertical, 16)
        }
        .background(Palette.deepInk.ignoresSafeArea())
        .navigationTitle(DayFormatting.monthTitle(month))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One reason code, expressed as a sentence, never a score.
    private func reasonText(_ reason: RepresentativeReason) -> String {
        switch reason {
        case .favoriteMedia: "This month is here because you favourited a photograph that day."
        case .archiveUniquePlace: "This month is here because that day is the only one at that place."
        case .greatestDistinctPlaceCount: "This month is here because that day has the most places."
        case .greatestMomentCount: "This month is here because that day has the most moments."
        case .greatestEligibleMediaCount: "This month is here because that day has the most photographs."
        case .nearestMonthMidpoint: "This month is here because that day sits nearest its middle."
        }
    }
}

private struct MonthDayRow: View {
    @Environment(LibraryModel.self) private var model
    let date: LocalDate

    var body: some View {
        let day = model.day(for: date)
        HStack(alignment: .center, spacing: 14) {
            Text("\(date.day)")
                .font(.editorial(20))
                .foregroundStyle(Palette.moonlightWhite)
                .frame(width: 34, alignment: .trailing)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 2) {
                let facts = DayFormatting.keyFacts(for: day)
                Text(facts.first ?? "Nothing recorded")
                    .font(.utility(14))
                    .foregroundStyle(facts.isEmpty ? Palette.dustyZinc : Palette.moonlightWhite)
                if facts.count > 1 {
                    Text(facts.dropFirst().joined(separator: " · "))
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
