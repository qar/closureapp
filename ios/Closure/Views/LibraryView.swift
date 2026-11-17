import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

enum LibraryRoute: Hashable {
    case album(String)
    case artist(String)
    case folder(String)
    case recentlyDeleted
    case duplicates
    case info
}

enum LibraryTab: String, CaseIterable, Identifiable {
    case albums = "Albums"
    case artists = "Artists"
    case folders = "Folders"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var tab: LibraryTab = .albums
    @State private var path = NavigationPath()
    @State private var showingImporter = false
    @State private var showingNowPlaying = false
    @State private var showingSearch = false
    @State private var showingFinderHelp = false
    @State private var showingDrive = false
    @State private var showingDownloads = false
    @State private var downloadsAfterDrive = false
    @Environment(DriveDownloadManager.self) private var downloads
    @Environment(GoogleDriveAccount.self) private var driveAccount
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
#if DEBUG
    @State private var debugImportStarted = false
    @State private var debugPreviewAlbum: Album?
#endif

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $path) {
            Group {
                if !library.isLoaded {
                    // The database loads in well under a second; show plain paper meanwhile.
                    Theme.paper
                } else if library.albums.isEmpty {
                    EmptyLibraryView(isImporting: library.isImporting || library.scanProgress != nil,
                                     progress: library.scanProgress,
                                     onImport: { showingImporter = true },
                                     onGoogleDrive: openGoogleDrive,
                                     onFinderHelp: { showingFinderHelp = true })
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            tabBar
                            content
                        }
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(Theme.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case let .album(id): AlbumView(albumID: id)
                case let .artist(name): ArtistView(artist: name)
                case let .folder(folder): FolderView(folder: folder)
                case .recentlyDeleted: RecentlyDeletedView()
                case .duplicates: DuplicatesView()
                case .info: LibraryInfoView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if DownloadStrip.isVisible(downloads) {
                    DownloadStrip { showingDownloads = true }
                }
                MiniPlayer { showingNowPlaying = true }
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.audio, .folder],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                Task { await library.importItems(urls) }
            }
        }
        .fullScreenCover(isPresented: $showingNowPlaying) { NowPlayingView() }
        .sheet(item: $library.importSummary) { summary in
            ImportResultView(summary: summary)
        }
        .sheet(isPresented: $showingSearch) {
            SearchView { route in
                showingSearch = false
                path.append(route)
            }
        }
        .sheet(isPresented: $showingFinderHelp) { FinderHelpView() }
        .sheet(isPresented: $showingDrive, onDismiss: {
            if downloadsAfterDrive {
                downloadsAfterDrive = false
                showingDownloads = true
            }
        }) {
            DriveBrowserView(onImport: { downloadsAfterDrive = true })
                .presentationBackground(Theme.paper)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingDownloads) {
            DownloadsView()
                .presentationBackground(Theme.paper)
                .presentationDragIndicator(.visible)
        }
        .alert("Google Drive", isPresented: Binding(get: { library.driveError != nil }, set: { if !$0 { library.driveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.driveError ?? "")
        }
#if DEBUG
        .task(id: library.albums.count) { runDebugLaunchArguments() }
        .overlay {
            // -ClosureScreen albumpreview: the long-press card on a dimmed library.
            if let album = debugPreviewAlbum {
                Color.black.opacity(0.2).ignoresSafeArea()
                AlbumMenuPreview(album: album).clipShape(RoundedRectangle(cornerRadius: 13))
            }
        }
#endif
    }

    // MARK: - Header and tabs

    private var header: some View {
        HStack(alignment: .center) {
            Text("Library")
                .font(Theme.serif(46))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if library.isImporting {
                ProgressView().tint(Theme.ink).frame(width: 44, height: 44)
            }
            IconButton(systemName: "magnifyingglass", label: "Search") { showingSearch = true }
            Menu {
                Button("From Files", systemImage: "folder") { showingImporter = true }
                Button("From Google Drive", systemImage: "icloud.and.arrow.down") { openGoogleDrive() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Import")
            // Same weight and glyph as the "…" on Now Playing and in Google Drive.
            IconButton(systemName: "ellipsis", size: 20, weight: .semibold, label: "Library Info") { path.append(LibraryRoute.info) }
        }
        .padding(.leading, Theme.horizontalMargin)
        .padding(.trailing, 14)
        .padding(.top, 8)
    }

    private var tabBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 22) {
                ForEach(LibraryTab.allCases) { item in
                    Button { tab = item } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            MetaText(item.rawValue, color: tab == item ? Theme.ink : Theme.muted)
                            Rectangle()
                                .fill(tab == item ? Theme.ink : .clear)
                                .frame(height: 1.5)
                        }
                        .fixedSize()
                        .frame(minHeight: 32, alignment: .bottom)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            Hairline().padding(.top, 7)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .albums:
            countRow(left: "\(library.albums.count) albums", right: scanText ?? "Sort: Artist")
            AlbumGrid(albums: library.albums)
        case .artists:
            let artists = artistsList
            countRow(left: "\(artists.count) artists", right: "A–Z")
            listRows(artists.map { ListRow(title: $0.name, meta: "\($0.albums) album\($0.albums == 1 ? "" : "s") · \($0.tracks) track\($0.tracks == 1 ? "" : "s")", route: .artist($0.name)) })
        case .folders:
            let folders = foldersList
            countRow(left: "\(folders.count) folders", right: "A–Z")
            listRows(folders.map { ListRow(title: displayName($0.path), meta: "\($0.tracks) track\($0.tracks == 1 ? "" : "s")\(parentPath($0.path))", route: .folder($0.path)) })
        }
    }

    /// "Reading 120 / 3000" while new files are read.
    private var scanText: String? {
        guard let progress = library.scanProgress, progress.total > 0 else { return nil }
        return "Reading \(progress.done) / \(progress.total)"
    }

    /// Opens the Drive browser, signing in first when needed. Cancelling is not an error.
    private func openGoogleDrive() {
        guard !driveAccount.isSignedIn else {
            showingDrive = true
            return
        }
        Task {
            do {
                try await driveAccount.signIn { url, scheme in
                    do {
                        return try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: scheme,
                                                                               preferredBrowserSession: .shared)
                    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                        throw GoogleDrive.DriveError.cancelled
                    }
                }
                showingDrive = true
            } catch GoogleDrive.DriveError.cancelled {
                return
            } catch {
                library.driveError = error.localizedDescription
            }
        }
    }

    private func countRow(left: String, right: String) -> some View {
        HStack {
            MetaText(left, size: 10)
            Spacer()
            MetaText(right, size: 10)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private struct ListRow: Identifiable {
        let title: String
        let meta: String
        let route: LibraryRoute
        var id: LibraryRoute { route }
    }

    private func listRows(_ rows: [ListRow]) -> some View {
        LazyVStack(spacing: 0) {
            Hairline()
            ForEach(rows) { row in
                NavigationLink(value: row.route) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.title)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            MetaText(row.meta, size: 9.5, tracking: 1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Hairline()
            }
        }
        .padding(.horizontal, Theme.horizontalMargin)
    }

    // MARK: - Derived lists

    private var artistsList: [(name: String, albums: Int, tracks: Int)] {
        Dictionary(grouping: library.albums, by: \.artist)
            .map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + $1.tracks.count }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var foldersList: [(path: String, tracks: Int)] {
        Dictionary(grouping: library.albums.flatMap(\.tracks), by: \.folder)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func displayName(_ folder: String) -> String {
        folder.split(separator: "/").last.map(String.init) ?? "Library"
    }

    private func parentPath(_ folder: String) -> String {
        let parts = folder.split(separator: "/").dropLast()
        return parts.isEmpty ? "" : " · " + parts.joined(separator: "/")
    }

#if DEBUG
    /// Simulator checks without taps. -ClosureScreen accepts: album, nowplaying,
    /// signal, queue, import, artists, folders, search.
    private func runDebugLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-ClosureImportPath"), flag + 1 < arguments.count, !debugImportStarted {
            debugImportStarted = true
            let url = URL(fileURLWithPath: arguments[flag + 1])
            Task { await library.importItems([url]) }
            return
        }
        guard let flag = arguments.firstIndex(of: "-ClosureScreen"), flag + 1 < arguments.count,
              player.currentTrack == nil, let album = library.albums.first else { return }
        let screen = arguments[flag + 1]
        var target = album
        if let titleFlag = arguments.firstIndex(of: "-ClosureAlbum"), titleFlag + 1 < arguments.count,
           let match = library.albums.first(where: { $0.title.hasPrefix(arguments[titleFlag + 1]) }) {
            target = match
        }
        player.play(target.tracks, from: min(1, target.tracks.count - 1), context: target.title)
        // -ClosurePlayNext: insert tracks from another album, then log the queue.
        if arguments.contains("-ClosurePlayNext"), let other = library.albums.first(where: { $0.id != target.id }) {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let before = player.progress.position
                player.playNext([other.tracks[0]], context: other.title)
                player.playLast(Array(other.tracks.suffix(2)), context: other.title)
                try? await Task.sleep(for: .seconds(1))
                print(String(format: "[Closure] queue edit: %@ %.2f s -> %.2f s; queue %@", player.currentTrack?.title ?? "?",
                             before, player.progress.position, player.queue.map(\.title).joined(separator: ", ")))
            }
        }
        switch screen {
        case "album": path.append(LibraryRoute.album(target.id))
        case "nowplaying", "signal", "queue": showingNowPlaying = true
        case "artists": tab = .artists
        case "folders": tab = .folders
        case "search": showingSearch = true
        case "drive": showingDrive = true
        case "downloads": showingDownloads = true
        case "duplicates": path.append(LibraryRoute.duplicates)
        case "info", "storage": path.append(LibraryRoute.info)
        case "albumpreview": debugPreviewAlbum = target
        case "trash":
            // Deletes the second track of the target album, then opens Recently Deleted.
            Task {
                await library.delete(target.tracks[min(1, target.tracks.count - 1)])
                path.append(LibraryRoute.recentlyDeleted)
            }
        case "restore":
            Task { await library.restoreAll() }
        case "import":
            var report = FileImporter.Report()
            report.audioFiles = 12
            report.companionFiles = 5
            report.leftInPlace = ["Night Album/extras.zip"]
            library.importSummary = ImportSummary(source: "Finder", report: report)
        default: break
        }
    }
#endif
}

/// Two-column album grid.
struct AlbumGrid: View {
    let albums: [Album]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 21, alignment: .top),
                            GridItem(.flexible(), alignment: .top)],
                  spacing: 30) {
            ForEach(albums) { album in
                NavigationLink(value: LibraryRoute.album(album.id)) {
                    VStack(alignment: .leading, spacing: 0) {
                        ArtworkView(request: album.artworkRequest, title: album.title, pixelSize: 520)
                            // Printed, not floating: a hairline edge, no shadow (as on the album page).
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.ink.opacity(0.1), lineWidth: 1))
                        Text(album.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .padding(.top, 10)
                        Text(album.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .padding(.top, 2)
                        MetaText(album.format, size: 9.5, tracking: 1)
                            .padding(.top, 7)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .contextMenu {
                    QueueMenuItems(tracks: album.tracks, context: album.title)
                } preview: {
                    AlbumMenuPreview(album: album)
                }
            }
        }
        .padding(.horizontal, Theme.horizontalMargin)
    }
}

/// What a long press on an album lifts: the cover with its title and artist on paper,
/// with even margins, so the system's rounded preview never cuts the cover or the text.
struct AlbumMenuPreview: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(request: album.artworkRequest, title: album.title, pixelSize: 600)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.ink.opacity(0.1), lineWidth: 1))
            Text(album.title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .padding(.top, 14)
            Text(album.artist)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.top, 2)
            MetaText(album.format, size: 9.5, tracking: 1)
                .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 280)
        .background(Theme.paper)
    }
}
