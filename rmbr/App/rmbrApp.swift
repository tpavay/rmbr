import SwiftUI

@main
struct RmbrApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LibraryModel()
    @State private var thumbnails = ThumbnailStore()

    var body: some Scene {
        WindowGroup {
            LifeView()
                .environment(model)
                .environment(thumbnails)
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
