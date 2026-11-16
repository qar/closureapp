import SwiftUI

@main
struct ClosureApp: App {
    @State private var library = LibraryStore()
    @State private var player = PlayerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
                // Only the light "paper" palette is designed so far.
                .preferredColorScheme(.light)
                .tint(Theme.ink)
                .task { await library.rescan() }
                .onOpenURL { url in
                    // "Open in Closure" from the share sheet. iOS copies the file into
                    // Documents/Inbox; the inbox import moves it into the library.
                    Task {
                        if url.isFileURL, !url.path.hasPrefix(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path) {
                            await library.importItems([url])
                        } else {
                            await library.importInbox()
                        }
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        Task { await library.importInbox() }
                    }
                }
        }
    }
}
