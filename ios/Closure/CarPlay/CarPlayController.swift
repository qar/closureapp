import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        CarPlayController.shared.connect(interfaceController)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CarPlayController.shared.disconnect(interfaceController)
    }
}

/// The car display uses the same library and player as the iPhone scene.
@MainActor
final class CarPlayController: NSObject, @preconcurrency CPNowPlayingTemplateObserver {
    static let shared = CarPlayController()

    private weak var library: LibraryStore?
    private weak var player: PlayerModel?
    private weak var interfaceController: CPInterfaceController?
    private var albumsTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var detailRenderers: [ObjectIdentifier: () -> Void] = [:]
    private var detailPages: [ObjectIdentifier: Int] = [:]
    private var albumsPage = 0
    private var playlistsPage = 0

    func bind(library: LibraryStore, player: PlayerModel) {
        self.library = library
        self.player = player
        refresh()
    }

    func connect(_ controller: CPInterfaceController) {
        interfaceController = controller
        let albums = CPListTemplate(title: "Albums", sections: [])
        albums.tabTitle = "Albums"
        albums.tabImage = UIImage(systemName: "square.stack")
        addNowPlayingButton(to: albums)
        albumsTemplate = albums

        let playlists = CPListTemplate(title: "Playlists", sections: [])
        playlists.tabTitle = "Playlists"
        playlists.tabImage = UIImage(systemName: "music.note.list")
        addNowPlayingButton(to: playlists)
        playlistsTemplate = playlists

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "Queue"
        nowPlaying.add(self)

        refresh()
        controller.setRootTemplate(CPTabBarTemplate(templates: [albums, playlists]), animated: false) { success, error in
            if !success { NSLog("[Closure] CarPlay root template failed: %@", error?.localizedDescription ?? "unknown error") }
        }
        if let library {
            Task { [weak self] in
                await library.rescan()
                self?.refresh()
            }
        }
    }

    func disconnect(_ controller: CPInterfaceController) {
        guard interfaceController === controller else { return }
        CPNowPlayingTemplate.shared.remove(self)
        interfaceController = nil
        albumsTemplate = nil
        playlistsTemplate = nil
        detailRenderers.removeAll()
        detailPages.removeAll()
    }

    func refresh() {
        guard let interfaceController else { return }
        renderAlbums()
        renderPlaylists()
        let active = Set(interfaceController.templates.map { ObjectIdentifier($0) })
        detailRenderers = detailRenderers.filter { active.contains($0.key) }
        detailPages = detailPages.filter { active.contains($0.key) }
        for template in interfaceController.templates {
            detailRenderers[ObjectIdentifier(template)]?()
        }
    }

    private func renderAlbums() {
        guard let template = albumsTemplate, let library else { return }
        let albums = library.albums.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        albumsPage = update(template, items: albums, page: albumsPage,
                            emptyText: library.isLoaded ? "No albums" : "Loading library") { [weak self] album, _ in
            let detail = album.artist.isEmpty ? "\(album.tracks.count) songs" : "\(album.artist) · \(album.tracks.count) songs"
            let item = CPListItem(text: album.title, detailText: detail)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                self?.openAlbum(album.id)
                done()
            }
            self?.loadArtwork(album.artworkRequest, into: item)
            return item
        } onPage: { [weak self] page in
            self?.albumsPage = page
            self?.renderAlbums()
        }
    }

    private func renderPlaylists() {
        guard let template = playlistsTemplate, let library else { return }
        playlistsPage = update(template, items: library.playlists, page: playlistsPage,
                               emptyText: library.isLoaded ? "No playlists" : "Loading library") { [weak self] playlist, _ in
            let count = playlist.tracks(in: library.tracksByID).count
            let item = CPListItem(text: playlist.name, detailText: "\(count) songs")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                self?.openPlaylist(playlist.id)
                done()
            }
            return item
        } onPage: { [weak self] page in
            self?.playlistsPage = page
            self?.renderPlaylists()
        }
    }

    private func openAlbum(_ id: String) {
        guard let album = library?.albums.first(where: { $0.id == id }) else { return }
        openTracks(title: album.title, tracks: { [weak self] in
            self?.library?.albums.first(where: { $0.id == id })?.tracks ?? []
        }, selection: .newQueue)
    }

    private func openPlaylist(_ id: String) {
        guard let playlist = library?.playlist(id) else { return }
        openTracks(title: playlist.name, tracks: { [weak self] in
            guard let self, let library = self.library else { return [] }
            return library.playlist(id)?.tracks(in: library.tracksByID) ?? []
        }, selection: .newQueue)
    }

    private enum Selection { case newQueue, existingQueue }

    private func openTracks(title: String, tracks: @escaping () -> [Track], selection: Selection) {
        guard let interfaceController else { return }
        let template = CPListTemplate(title: title, sections: [])
        addNowPlayingButton(to: template)
        let identifier = ObjectIdentifier(template)
        detailPages[identifier] = 0
        detailRenderers[identifier] = { [weak self, weak template] in
            guard let self, let template else { return }
            let current = tracks()
            self.detailPages[identifier] = self.update(template, items: current,
                                                        page: self.detailPages[identifier] ?? 0,
                                                        emptyText: "No songs") { [weak self] track, rowIndex in
                let item = CPListItem(text: track.title, detailText: track.artist)
                item.isPlaying = self?.player?.currentTrack?.id == track.id && self?.player?.isPlaying == true
                item.handler = { [weak self] _, done in
                    defer { done() }
                    guard let self, let player = self.player else { return }
                    let latest = tracks()
                    let index = latest.indices.contains(rowIndex) && latest[rowIndex].id == track.id
                        ? rowIndex : latest.firstIndex(where: { $0.id == track.id })
                    guard let index else { return }
                    switch selection {
                    case .newQueue:
                        player.play(latest, from: index, context: title)
                        self.showNowPlaying()
                    case .existingQueue:
                        player.playQueueIndex(index)
                        self.interfaceController?.popTemplate(animated: true, completion: nil)
                    }
                }
                return item
            } onPage: { [weak self] page in
                self?.detailPages[identifier] = page
                self?.detailRenderers[identifier]?()
            }
        }
        detailRenderers[identifier]?()
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func showNowPlaying() {
        guard let interfaceController, player?.currentTrack != nil else { return }
        let template = CPNowPlayingTemplate.shared
        guard interfaceController.topTemplate !== template else { return }
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        openTracks(title: "Queue", tracks: { [weak self] in self?.player?.queue ?? [] }, selection: .existingQueue)
    }

    private func addNowPlayingButton(to template: CPListTemplate) {
        let button = CPBarButton(title: "Now Playing") { [weak self] _ in self?.showNowPlaying() }
        button.isEnabled = player?.currentTrack != nil
        template.trailingNavigationBarButtons = [button]
    }

    private func loadArtwork(_ request: ArtworkStore.Request, into item: CPListItem) {
        let scale = interfaceController?.carTraitCollection.displayScale ?? 2
        let pixels = Int(CPListItem.maximumImageSize.width * scale)
        Task { [weak self, weak item] in
            guard let image = await ArtworkStore.shared.image(for: request, pixelSize: pixels),
                  self?.interfaceController != nil else { return }
            item?.setImage(image)
        }
    }

    @discardableResult
    private func update<T>(_ template: CPListTemplate, items: [T], page: Int, emptyText: String,
                           row: (T, Int) -> CPListItem, onPage: @escaping (Int) -> Void) -> Int {
        let slice = CarPlayPage(total: items.count, requested: page, maximumItems: CPListTemplate.maximumItemCount)
        var rows: [CPListItem] = []
        if slice.hasPrevious {
            let previous = CPListItem(text: "Previous", detailText: nil)
            previous.handler = { _, done in onPage(slice.number - 1); done() }
            rows.append(previous)
        }
        for index in slice.range { rows.append(row(items[index], index)) }
        if slice.hasNext {
            let next = CPListItem(text: "Next", detailText: nil)
            next.handler = { _, done in onPage(slice.number + 1); done() }
            rows.append(next)
        }
        if rows.isEmpty {
            let empty = CPListItem(text: emptyText, detailText: nil)
            empty.isEnabled = false
            rows.append(empty)
        }
        template.updateSections([CPListSection(items: rows)])
        addNowPlayingButton(to: template)
        return slice.number
    }
}
