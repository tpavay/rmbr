import SwiftUI

@main
struct RmbrApp: App {
    @State private var model = LibraryModel()
    @State private var thumbnails = ThumbnailStore()

    var body: some Scene {
        WindowGroup {
            LifeView()
                .environment(model)
                .environment(thumbnails)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}
