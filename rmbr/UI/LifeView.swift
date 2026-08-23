import SwiftUI

/// The scroll through a life.
///
/// The photograph is the row. A day that holds nothing keeps a card of its own so time
/// never skips over one quiet Wednesday; two or more consecutive empty days collapse
/// into a single row a third the height, so a quiet fortnight does not become fourteen
/// outlines. The calendar in the top right lifts out to the month.
struct LifeView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ThumbnailStore.self) private var thumbnails
    @State private var showingDiagnostics = false
    @State private var pinnedMonth: Month?

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

    // MARK: - Chrome

    private var chrome: some View {
        HStack(alignment: .center) {
            // The diagnostics sheet is instrumentation rather than product, so it has no
            // control of its own. A long press on the wordmark is how a developer reaches
            // it without putting a gauge on the first screen anybody ever sees.
            Text("rmbr")
                .font(.editorial(25, weight: .semibold))
                .foregroundStyle(Palette.moonlightWhite)
                .onLongPressGesture(minimumDuration: 0.8) { showingDiagnostics = true }
                .accessibilityAddTraits(.isHeader)
            Spacer()
            NavigationLink {
                MonthView(month: pinnedMonth ?? Month(year: model.today.year, month: model.today.month))
            } label: {
                CalendarGlyph(isActive: false)
                    .frame(width: 44, height: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { Haptics.soft() })
            .accessibilityLabel("Browse by month")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
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
            FailedView(message: message)

        case .ready:
            if model.lifeEntries.isEmpty {
                VStack(spacing: 0) {
                    chrome
                    EmptyLibraryNotice(access: model.access, onChoose: { model.presentLimitedPicker() })
                }
            } else {
                scroll
            }
        }
    }

    // MARK: - The scroll

    private var scroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                chrome
                // Sections rather than a flat list, so the month rule pins under the
                // wordmark and is pushed off by the next one instead of scrolling away.
                ForEach(months, id: \.header.id) { section in
                    Section {
                        ForEach(section.rows) { entry in
                            row(for: entry)
                        }
                    } header: {
                        row(for: section.header)
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
            announceMonth(for: visible)
        }
        .onDisappear { thumbnails.stopPreheating(window: Self.preheatWindow) }
    }

    /// The entries grouped under the month rule they belong to.
    ///
    /// The builder already emits them in order, so this is a walk rather than a sort.
    private var months: [(header: LifeEntry, rows: [LifeEntry])] {
        var sections: [(header: LifeEntry, rows: [LifeEntry])] = []
        for entry in model.lifeEntries {
            if case .monthHeader = entry {
                sections.append((header: entry, rows: []))
            } else if !sections.isEmpty {
                sections[sections.count - 1].rows.append(entry)
            }
        }
        return sections
    }

    @ViewBuilder
    private func row(for entry: LifeEntry) -> some View {
        switch entry {
        case .monthHeader(let month, let subtitle):
            MonthRule(month: month, subtitle: subtitle)
        case .day(let date, let treatment):
            NavigationLink {
                DayPageView(date: date)
            } label: {
                DayCard(date: date, treatment: treatment)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { Haptics.soft() })
        case .emptyDay(let date):
            NavigationLink {
                DayPageView(date: date)
            } label: {
                EmptyDayCard(date: date, today: model.today)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { Haptics.soft() })
        case .gap(let newest, let oldest, let days):
            NavigationLink {
                MonthView(month: Month(year: newest.year, month: newest.month))
            } label: {
                GapRow(newest: newest, oldest: oldest, days: days)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { Haptics.soft() })
        case .emptyMonth(let month, let reason):
            EmptyMonthRow(month: month, reason: reason)
        }
    }

    private static let preheatWindow = "life"
    private static let coverTargetSize = CGSize(width: 900, height: 900)
    /// Rows either side of what is visible that are worth having decoded already.
    private static let preheatMargin = 6

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

    /// The month the rule is showing, and the one the calendar button opens.
    private func announceMonth(for visibleIDs: [String]) {
        let entries = model.lifeEntries
        let visible = Set(visibleIDs)
        let month = entries.first { visible.contains($0.id) }.flatMap { entry -> Month? in
            switch entry {
            case .monthHeader(let month, _): month
            case .day(let date, _), .emptyDay(let date): Month(year: date.year, month: date.month)
            case .gap(let newest, _, _): Month(year: newest.year, month: newest.month)
            case .emptyMonth(let month, _): month
            }
        }
        guard let month, month != pinnedMonth else { return }
        // A crossed threshold, not arriving data: this is the one thing the scroll says
        // with the Taptic engine.
        if pinnedMonth != nil { Haptics.selection() }
        pinnedMonth = month
    }
}

// MARK: - Rows

private struct MonthRule: View {
    let month: Month
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Text(DayFormatting.monthTitle(month))
                .sectionLabelStyle()
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
            Text(subtitle)
                .font(.utility(10))
                .foregroundStyle(Palette.dustyZinc)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Palette.deepInk)
    }
}

private struct DayCard: View {
    @Environment(LibraryModel.self) private var model
    let date: LocalDate
    let treatment: BackfillTreatment

    var body: some View {
        let day = model.day(for: date)
        let isToday = date == model.today
        ZStack(alignment: .bottomLeading) {
            Group {
                if let coverID = day.media.coverMediaID, let reference = day.media(coverID) {
                    MediaThumbnail(reference: reference, targetSize: CGSize(width: 900, height: 900))
                } else {
                    Rectangle().fill(Palette.smokedGlass)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 228)
            .clipped()

            LinearGradient(
                colors: [
                    Palette.deepInk.opacity(0.92),
                    Palette.deepInk.opacity(0.30),
                    .clear
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 228)

            VStack(alignment: .leading, spacing: 4) {
                Text(DayFormatting.heading(for: date, today: model.today))
                    .font(.editorial(22))
                    .foregroundStyle(isToday ? Palette.emberGlow : Palette.moonlightWhite)
                    .lineLimit(2)
                ForEach(DayFormatting.cardFacts(for: day), id: \.self) { fact in
                    Text(fact)
                        .font(.utility(11))
                        .foregroundStyle(Palette.moonlightWhite.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 13)
        }
        .frame(height: 228)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Palette.emberGlow.opacity(0.5), lineWidth: 1)
            }
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }
}

/// A day inside the window that holds nothing.
///
/// The same height as a day that was lived, because giving it less would be a judgement
/// about the day rather than a statement about what rmbr has.
private struct EmptyDayCard: View {
    let date: LocalDate
    let today: LocalDate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(DayFormatting.heading(for: date, today: today))
                .font(.editorial(22))
                .foregroundStyle(Palette.moonlightWhite.opacity(0.6))
            Text("Nothing recorded")
                .font(.utility(11))
                .foregroundStyle(Palette.dustyZinc)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 228, alignment: .bottomLeading)
        .padding(.horizontal, 15)
        .padding(.bottom, 13)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    Color.white.opacity(0.20),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }
}

/// Two or more consecutive empty days.
private struct GapRow: View {
    let newest: LocalDate
    let oldest: LocalDate
    let days: Int

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DayFormatting.span(from: oldest, to: newest))
                    .font(.editorial(15))
                    .foregroundStyle(Palette.moonlightWhite.opacity(0.6))
                Text("Nothing recorded")
                    .font(.utility(10.5))
                    .foregroundStyle(Palette.dustyZinc)
            }
            Spacer(minLength: 0)
            Text(DayFormatting.count(days, singular: "day", plural: "days"))
                .font(.utility(10))
                .foregroundStyle(Palette.dustyZinc)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Color.white.opacity(0.20),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        }
        .padding(.horizontal, 20)
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

// MARK: - The calendar glyph

struct CalendarGlyph: View {
    var isActive: Bool

    var body: some View {
        let tint = isActive ? Palette.emberGlow : Palette.dustyZinc
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(tint, lineWidth: 1.4)
            .frame(width: 26, height: 26)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(tint)
                    .frame(height: 1.4)
                    .padding(.top, 6)
            }
            .overlay(alignment: .top) {
                HStack(spacing: 10) {
                    Rectangle().fill(tint).frame(width: 1.4, height: 5)
                    Rectangle().fill(tint).frame(width: 1.4, height: 5)
                }
                .offset(y: -3)
            }
    }
}

// MARK: - Phases

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
                Haptics.soft()
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

private struct FailedView: View {
    let message: String

    var body: some View {
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
