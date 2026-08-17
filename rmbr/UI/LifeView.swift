import SwiftUI

/// The scroll through a life.
///
/// Deliberately rough. The point of this milestone is what a day contains, not how
/// finished the page looks, so this is the smallest surface that lets a person judge
/// the reconstruction honestly.
struct LifeView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ThumbnailStore.self) private var thumbnails
    @State private var showingDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.deepInk.ignoresSafeArea()
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsView()
            }
        }
        .tint(Palette.emberGlow)
    }

    private var wordmark: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("rmbr")
                .font(.editorial(28, weight: .semibold))
                .foregroundStyle(Palette.moonlightWhite)
            Spacer()
            Button {
                showingDiagnostics = true
            } label: {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.dustyZinc)
                    .frame(width: 44, height: 44, alignment: .trailing)
            }
            .accessibilityLabel("Reconstruction details")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checkingPermission:
            ProgressView().tint(Palette.dustyZinc)

        case .awaitingPermission:
            PermissionPrompt()

        case .permissionRefused(let access):
            RefusedView(access: access)

        case .indexing(let done, let total):
            IndexingView(done: done, total: total)

        case .failed(let message):
            VStack(spacing: 12) {
                Text("Reconstruction stopped.")
                    .font(.editorial(22))
                    .foregroundStyle(Palette.moonlightWhite)
                Text(message)
                    .font(.utility(13))
                    .foregroundStyle(Palette.dustyZinc)
                    .multilineTextAlignment(.center)
            }
            .padding(32)

        case .ready:
            scroll
        }
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                wordmark
                ForEach(model.lifeEntries) { entry in
                    switch entry {
                    case .monthHeader(let month, let subtitle):
                        MonthHeaderRow(month: month, subtitle: subtitle)
                    case .day(let date, let treatment):
                        NavigationLink {
                            DayPageView(date: date)
                        } label: {
                            DayRow(date: date, treatment: treatment)
                        }
                        .buttonStyle(.plain)
                    case .emptyMonth(let month, let reason):
                        EmptyMonthRow(month: month, reason: reason)
                    }
                }
                PlaceAttributionFooter(attributions: model.placeAttributions)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            .padding(.bottom, 48)
            .scrollTargetLayout()
        }
        // PhotoKit is told what is about to be needed rather than being asked for it a
        // row at a time as it arrives on screen.
        .onScrollTargetVisibilityChange(idType: String.self) { visible in
            preheatCovers(around: visible)
        }
        .onDisappear { thumbnails.stopPreheating(window: Self.preheatWindow) }
    }

    private static let preheatWindow = "life"
    private static let coverTargetSize = CGSize(width: 220, height: 220)
    /// Rows either side of what is visible that are worth having decoded already.
    private static let preheatMargin = 8

    private func preheatCovers(around visibleIDs: [String]) {
        let entries = model.lifeEntries
        let visible = Set(visibleIDs)
        let indices = entries.indices.filter { visible.contains(entries[$0].id) }
        guard let first = indices.min(), let last = indices.max() else { return }
        let lower = max(entries.startIndex, first - Self.preheatMargin)
        let upper = min(entries.endIndex - 1, last + Self.preheatMargin)

        let references = entries[lower...upper].compactMap { entry -> MediaReference? in
            guard case .day(let date, _) = entry else { return nil }
            let day = model.day(for: date)
            guard let coverID = day.media.coverMediaID else { return nil }
            return day.media(coverID)
        }
        thumbnails.preheat(
            references,
            targetSize: Self.coverTargetSize,
            window: Self.preheatWindow
        )
    }
}

private struct MonthHeaderRow: View {
    @Environment(LibraryModel.self) private var model
    let month: Month
    let subtitle: String

    var body: some View {
        NavigationLink {
            MonthView(month: month)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(DayFormatting.monthTitle(month))
                    .font(.editorial(15, weight: .semibold))
                    .foregroundStyle(Palette.moonlightWhite)
                Spacer()
                Text(subtitle)
                    .sectionLabelStyle()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Palette.deepInk)
        }
        .buttonStyle(.plain)
    }
}

private struct DayRow: View {
    @Environment(LibraryModel.self) private var model
    let date: LocalDate
    let treatment: BackfillTreatment

    var body: some View {
        let day = model.day(for: date)
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let coverID = day.media.coverMediaID, let reference = day.media(coverID) {
                    MediaThumbnail(reference: reference, targetSize: CGSize(width: 220, height: 220))
                } else {
                    Rectangle().fill(Palette.smokedGlass)
                }
            }
            .frame(width: 68, height: 85)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(DayFormatting.heading(for: date, today: model.today))
                    .font(.editorial(18))
                    .foregroundStyle(
                        date == model.today ? Palette.emberGlow : Palette.moonlightWhite
                    )
                    .lineLimit(2)

                let facts = DayFormatting.keyFacts(for: day)
                if facts.isEmpty {
                    // Limited access leaves the counts unknown, so a day with real
                    // photographs on it can have no fact to state. It says what rmbr can
                    // see rather than claiming the day held nothing.
                    Text(DayFormatting.rowFallback(for: day))
                        .font(.utility(13))
                        .foregroundStyle(Palette.dustyZinc)
                } else {
                    ForEach(facts, id: \.self) { fact in
                        Text(fact)
                            .font(.utility(13))
                            .foregroundStyle(Palette.dustyZinc)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct EmptyMonthRow: View {
    let month: Month
    let reason: NoRepresentativeReason

    var body: some View {
        // A month with nothing worth showing stays visibly thin. rmbr does not promote
        // the least bad day to fill the gap (RE-047).
        Text(reason == .noIndexedDays
             ? "No photographs from this month."
             : "No day from this month has enough to show.")
            .font(.utility(13))
            .foregroundStyle(Palette.dustyZinc)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
    }
}

private struct PermissionPrompt: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Text("rmbr rebuilds your days from your photographs.")
                .font(.editorial(26))
                .foregroundStyle(Palette.moonlightWhite)
                .multilineTextAlignment(.center)
            Text("Nothing leaves this phone except a coordinate, sent to look up a place name.")
                .font(.utility(14))
                .foregroundStyle(Palette.dustyZinc)
                .multilineTextAlignment(.center)
            Button("Allow access to photographs") {
                Task { await model.requestAccess() }
            }
            .font(.utility(15, weight: .semibold))
            .foregroundStyle(Palette.deepInk)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Palette.emberGlow, in: Capsule())
        }
        .padding(32)
    }
}

private struct RefusedView: View {
    let access: PhotoLibraryAccess

    var body: some View {
        VStack(spacing: 12) {
            Text("rmbr cannot see your photographs.")
                .font(.editorial(22))
                .foregroundStyle(Palette.moonlightWhite)
                .multilineTextAlignment(.center)
            Text("There is nothing to rebuild a day from. Photo access can be changed in Settings.")
                .font(.utility(13))
                .foregroundStyle(Palette.dustyZinc)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

private struct IndexingView: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 14) {
            Text("Reading your library")
                .font(.editorial(24))
                .foregroundStyle(Palette.moonlightWhite)
            // A real counter, not a spinner and not a promise about when it finishes.
            Text(total > 0 ? "\(done.formatted()) of \(total.formatted()) captures" : "Starting")
                .font(.utility(14))
                .foregroundStyle(Palette.dustyZinc)
                .monospacedDigit()
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                .tint(Palette.emberGlow)
                .frame(maxWidth: 260)
        }
        .padding(32)
    }
}
