import SwiftUI
import UIKit

/// Hands the system's completion handler for background download events to the
/// download manager, which calls it once every event is delivered.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DriveDownloadManager.sessionIdentifier else { return completionHandler() }
        MainActor.assumeIsolated { DriveDownloadManager.backgroundEventsDone = completionHandler }
    }
}

@main
struct ClosureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: LibraryStore
    @State private var player: PlayerModel
    @State private var driveAccount: GoogleDriveAccount
    @State private var downloads: DriveDownloadManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Created here, not lazily, so a background relaunch for download events finds
        // the session and the saved job.
        let library = LibraryStore()
        let player = PlayerModel()
        let account = GoogleDriveAccount()
        let downloads = DriveDownloadManager(root: DriveDownloadManager.appRoot,
                                             configuration: DriveDownloadManager.appConfiguration()) {
            try await account.validAccessToken()
        }
        downloads.importFiles = { [weak library] sources in
            await library?.importDownloaded(sources) ?? FileImporter.Report()
        }
        downloads.filesAlreadyInLibrary = { [weak library] files in
            await library?.filesAlreadyInLibrary(files) ?? []
        }
#if DEBUG
        DriveDownloadManager.loadDemoIfRequested(downloads)
#endif
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        _driveAccount = State(initialValue: account)
        _downloads = State(initialValue: downloads)
        CarPlayController.shared.bind(library: library, player: player)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
                .environment(driveAccount)
                .environment(downloads)
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
                .onChange(of: library.albums) { _, albums in
                    player.refreshTracks(from: albums)
                    CarPlayController.shared.refresh()
                }
                .onChange(of: library.playlists) { _, _ in CarPlayController.shared.refresh() }
                .onChange(of: player.queue) { _, _ in CarPlayController.shared.refresh() }
                .onChange(of: player.currentIndex) { _, _ in CarPlayController.shared.refresh() }
                .onChange(of: player.isPlaying) { _, _ in CarPlayController.shared.refresh() }
                .onChange(of: library.isLoaded, initial: true) { _, loaded in
                    // Put back what was playing last time, paused.
                    // Debug screens start their own playback.
                    if loaded, !ProcessInfo.processInfo.arguments.contains("-ClosureScreen") {
                        player.restore(from: library.albums)
                    }
#if DEBUG
                    // -ClosureResume: press play after the restore and log where playback is.
                    if loaded, ProcessInfo.processInfo.arguments.contains("-ClosureResume") {
                        player.resume()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            print(String(format: "[Closure] resumed: track %d at %.1f s, playing %d",
                                         player.currentIndex + 1, player.progress.position, player.isPlaying ? 1 : 0))
                        }
                    }
#endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        Task { await library.importInbox() }
                    }
                    Task { await downloads.setBackground(phase == .background) }
                    if phase != .active { player.saveState() }
                }
        }
    }
}
