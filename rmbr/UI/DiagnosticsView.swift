import SwiftUI

/// What the reconstruction cost, and where the place-name key lives.
///
/// This screen is not part of the product. It exists so the first run on a real library
/// produces a number worth reporting rather than an impression, and so the Geoapify key
/// can be entered on the device without ever being written into a file or a build.
struct DiagnosticsView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var keyEntry = ""
    @State private var rebuilding = false

    var body: some View {
        NavigationStack {
            List {
                Section("First run") {
                    if let metrics = model.metrics {
                        row("Assets walked", metrics.assetCount.formatted())
                        row("Records indexed", metrics.recordCount.formatted())
                        row("Fetch", seconds(metrics.fetchSeconds))
                        row("Property walk", seconds(metrics.walkSeconds))
                        row("Persist", seconds(metrics.persistSeconds))
                        row("Total", seconds(metrics.totalSeconds))
                        row("Rate", "\(Int(metrics.assetsPerSecond.rounded())) assets/sec")
                        row("Geotagged", metrics.geotaggedCount.formatted())
                        row("Screenshots", metrics.screenshotCount.formatted())
                        row("Archive survey", seconds(model.surveySeconds))
                        row("Days composed up front", model.composedDayCount.formatted())
                        row("Backfill composition", seconds(model.composeSeconds))
                        row("Loaded from cache", model.loadedFromCache ? "yes" : "no")
                    } else {
                        Text("Not indexed yet.")
                            .foregroundStyle(Palette.dustyZinc)
                    }
                }

                Section("Library") {
                    row("Access", accessDescription)
                    row("Records", model.indexedRecordCount.formatted())
                    if let earliest = model.earliestIndexedDate {
                        row("Reaches back to", earliest.description)
                    }
                    row("Months with a representative", representativeCount.formatted())
                    row("Months with nothing to show", emptyMonthCount.formatted())
                }

                Section("Place names") {
                    row("Geoapify key", model.hasPlaceCredential ? "stored on device" : "not stored")
                    row("Labels kept", model.ledgerLabelCount.formatted())
                    row("Requested this session", model.placeReport.requested.formatted())
                    row("Resolved", model.placeReport.resolved.formatted())
                    row("No label supported", model.placeReport.unlabelled.formatted())
                    if model.placeReport.failed > 0 {
                        row("Failed", model.placeReport.failed.formatted())
                    }
                    if model.placeReport.skippedForBudget > 0 {
                        // A cap is stated out loud. Quietly returning fewer names would
                        // read as "these days had no places".
                        row("Skipped for daily budget", model.placeReport.skippedForBudget.formatted())
                    }
                    if !model.placeReport.labelsPersisted {
                        // A label held only in memory is not the permanent record the
                        // ledger promises, and will be asked for again next launch.
                        row("Saved to ledger", "no")
                    }
                    if let error = model.placeReport.lastError {
                        Text(error)
                            .font(.utility(11))
                            .foregroundStyle(Palette.dustyZinc)
                    }

                    SecureField("Geoapify API key", text: $keyEntry)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Store key in this device's keychain") {
                        model.storePlaceCredential(keyEntry)
                        keyEntry = ""
                    }
                    .disabled(keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasPlaceCredential {
                        Button("Remove key", role: .destructive) {
                            model.removePlaceCredential()
                        }
                    }
                    Text("Place names \(OpenStreetMap.attribution), via Geoapify.")
                        .font(.utility(11))
                        .foregroundStyle(Palette.dustyZinc)
                }

                Section("Engine") {
                    row("Engine version", ReconstructionVersion.engine)
                    row("Tuning profile", model.tuning.version)
                    row("Day boundary", "civil midnight (no sleep source in scope)")
                    Button(rebuilding ? "Rebuilding…" : "Rebuild index from scratch") {
                        rebuilding = true
                        Task {
                            await model.loadOrBuildIndex(forceRebuild: true)
                            rebuilding = false
                        }
                    }
                    .disabled(rebuilding)
                }
            }
            .navigationTitle("Reconstruction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var accessDescription: String {
        switch model.access {
        case .full: "full library"
        case .limited: "limited selection"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked"
        }
    }

    private var representativeCount: Int {
        model.monthEntries.filter { if case .representative = $0 { true } else { false } }.count
    }

    private var emptyMonthCount: Int {
        model.monthEntries.filter { if case .noRepresentative = $0 { true } else { false } }.count
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.utility(13))
    }

    private func seconds(_ value: Double) -> String {
        value >= 1 ? String(format: "%.2f s", value) : String(format: "%.0f ms", value * 1000)
    }
}
