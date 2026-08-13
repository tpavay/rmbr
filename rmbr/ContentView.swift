import SwiftUI
import UIKit

enum SpikeMode: String, CaseIterable, Identifiable {
    case survey = "A - History survey"
    case day = "B - Reconstruct a day"
    var id: String { rawValue }
}

@MainActor
@Observable
final class SpikeModel {

    var mode: SpikeMode = .survey
    var selectedDate = Date()
    var isRunning = false
    var progressMessage = ""
    var output = SpikeModel.welcome

    static let welcome = """
    rmbr - PHASE 0 MEASUREMENT SPIKE

    Two questions, no product:

      MODE A  how much past is there? Counts every photo, every health sample and
              every year of both, and states plainly what iOS refuses to hand over.

      MODE B  what does one day actually look like? Prints a chosen day's raw
              material in time order, then the moments a simple heuristic proposes.

    Pick a mode and press RUN. Permission sheets appear on the first run of each.
    Mode A takes a while on a real library - it walks every asset and every month of
    health history. Leave it in the foreground until it finishes.

    Use the share button to send the result back.
    """

    /// Simulator runs pass this so the three permission sheets never appear and the
    /// refused/empty paths can be exercised without a human tapping anything.
    private var skipPermissionRequests: Bool {
        ProcessInfo.processInfo.arguments.contains("-skip-permission-requests")
    }

    private func note(_ message: String) {
        progressMessage = message
    }

    private var progressSink: @Sendable (String) -> Void {
        { [weak self] message in
            Task { @MainActor in self?.progressMessage = message }
        }
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        output = ""
        defer { isRunning = false; progressMessage = "" }

        switch mode {
        case .survey: await runSurvey()
        case .day: await runDay()
        }
    }

    // MARK: Mode A

    private func runSurvey() async {
        note("Asking for permissions…")
        let photoState = skipPermissionRequests ? Permissions.photoState() : await Permissions.requestPhotos()
        let health: (state: PermissionState, note: String) = skipPermissionRequests
            ? (state: Permissions.healthStateWithoutAsking(), note: "Permission sheets were skipped for this run.")
            : await Permissions.requestHealth()
        if !skipPermissionRequests {
            await LocationProbe.shared.requestAuthorization()
        }

        var text = header(photoState: photoState, healthState: health.state)
        text += "\n\n"

        note("Surveying photos…")
        let photos = await PhotoSurvey.run(progress: progressSink)
        text += PhotoSurvey.report(photos) + "\n\n"

        note("Surveying health…")
        let healthResult = await HealthSurvey.run(state: health.state, note: health.note, progress: progressSink)
        text += HealthSurvey.report(healthResult) + "\n\n"

        note("Probing location…")
        await LocationProbe.shared.probe(progress: progressSink)
        text += LocationProbe.shared.report() + "\n"

        text += "\n" + Fmt.rule("end of survey") + "\n"
        output = text
    }

    // MARK: Mode B

    private func runDay() async {
        note("Asking for permissions…")
        let photoState = skipPermissionRequests ? Permissions.photoState() : await Permissions.requestPhotos()
        let health: (state: PermissionState, note: String) = skipPermissionRequests
            ? (state: Permissions.healthStateWithoutAsking(), note: "Permission sheets were skipped for this run.")
            : await Permissions.requestHealth()

        var text = header(photoState: photoState, healthState: health.state)
        text += "\n\n"

        note("Reconstructing \(Fmt.date(selectedDate))…")
        let day = await DayReconstruction.run(date: selectedDate, progress: progressSink)
        text += DayReport.render(day) + "\n"

        text += "\n" + Fmt.rule("end of day") + "\n"
        output = text
    }

    /// Lets the spike be driven from the command line so the output can be read
    /// without tapping a simulator:
    ///     xcrun simctl launch --console booted com.TylerPavay.rmbr -autorun-survey
    ///     xcrun simctl launch --console booted com.TylerPavay.rmbr -autorun-day 2026-08-12
    func autorunIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-autorun-survey") {
            mode = .survey
        } else if let index = arguments.firstIndex(of: "-autorun-day"),
                  index + 1 < arguments.count,
                  let date = Fmt.dateOnly.date(from: arguments[index + 1]) {
            mode = .day
            selectedDate = date
        } else {
            return
        }
        await run()
        print(output)
    }

    // MARK: Header

    private func header(photoState: PermissionState, healthState: PermissionState) -> String {
        var out = "rmbr phase 0 spike\n"
        out += "run at   : \(Fmt.stamp(Date()))\n"
        out += "device   : \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)\n"
        out += "timezone : \(TimeZone.current.identifier)\n"
        #if targetEnvironment(simulator)
        out += "\n*** RUNNING IN THE SIMULATOR. These numbers describe a simulator, not a\n"
        out += "*** phone. Nothing here is an answer to the blocking question.\n"
        #endif
        out += "\nPERMISSIONS AS GRANTED\n"
        out += "  Photos   : \(photoState.rawValue)\n"
        out += "  Health   : \(healthState.rawValue)\n"
        out += "  Location : \(Permissions.locationStateDescription())\n"
        return out
    }
}

struct ContentView: View {

    @State private var model = SpikeModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                transcript
            }
            .task { await model.autorunIfRequested() }
            .navigationTitle("rmbr spike")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = model.output
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(model.output.isEmpty)

                    ShareLink(item: model.output) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.output.isEmpty)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $model.mode) {
                ForEach(SpikeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)

            if model.mode == .day {
                DatePicker(
                    "Date",
                    selection: $model.selectedDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .disabled(model.isRunning)
            }

            HStack {
                Button("RUN") {
                    Task { await model.run() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)

                if model.isRunning {
                    ProgressView()
                    Text(model.progressMessage)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
        }
        .padding()
    }

    private var transcript: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(model.output)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(8)
        }
    }
}

#Preview {
    ContentView()
}
