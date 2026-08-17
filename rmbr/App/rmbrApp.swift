import SwiftUI

@main
struct RmbrApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LifeView()
                .environment(model)
                // The model owns the thumbnail store, so a narrowed grant drops the index
                // and the pixels drawn from it in one go. Releasing them from a SwiftUI
                // callback here would be a turn of the main actor too late.
                .environment(model.thumbnails)
                .preferredColorScheme(.dark)
                .task { await model.start() }
                // Photo access is granted, narrowed and revoked in Settings, so what
                // rmbr is allowed to see can be different every time it comes back.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.refresh() }
                }
        }
    }
}
