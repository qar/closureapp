import SwiftUI

/// Files and folders picked in the Drive browser, kept while moving between folders.
@MainActor
@Observable
final class DriveSelection {
    private(set) var items: [String: GoogleDrive.File] = [:]
    var count: Int { items.count }
    var files: [GoogleDrive.File] { Array(items.values) }

    func contains(_ file: GoogleDrive.File) -> Bool { items[file.id] != nil }

    func toggle(_ file: GoogleDrive.File) {
        if items[file.id] == nil { items[file.id] = file } else { items[file.id] = nil }
    }

    func clear() { items.removeAll() }
}

/// Google Drive inside the app: browse My Drive, shared drives and files shared with
/// you; pick files or whole folders; import them.
struct DriveBrowserView: View {
    @Environment(GoogleDriveAccount.self) private var account
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selection = DriveSelection()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            DriveHomeView(onClose: { dismiss() })
                .navigationDestination(for: GoogleDrive.Location.self) { location in
                    DriveFolderView(location: location)
                }
        }
        .environment(selection)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.count > 0 { importBar }
        }
#if DEBUG
        .onAppear {
            // -ClosureDrivePath: open My Drive › Music with two items picked, for screenshots.
            guard DriveDemo.isOn, ProcessInfo.processInfo.arguments.contains("-ClosureDrivePath"), path.isEmpty else { return }
            path.append(GoogleDrive.Location.myDrive)
            path.append(GoogleDrive.Location.folder(id: "m", name: "Music"))
            selection.toggle(.init(id: "a1", name: "Low Light (Deluxe Edition)", mimeType: GoogleDrive.folderMimeType))
            selection.toggle(.init(id: "f1", name: "01 Arrival.flac", mimeType: "audio/flac", size: "31457280"))
        }
#endif
    }

    private var importBar: some View {
        HStack(spacing: 16) {
            MetaText("\(selection.count) selected", size: 10.5, color: Theme.ink)
            Button("Clear") { selection.clear() }
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            Spacer()
            Button("Import") {
                let items = selection.files
                let client = account.client()
                dismiss()
                Task { await library.importFromDrive(items, client: client) }
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.vertical, 10)
        .background(Theme.paper2.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct DriveHomeView: View {
    let onClose: () -> Void
    @Environment(GoogleDriveAccount.self) private var account

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    IconButton(systemName: "xmark", size: 18, weight: .semibold, label: "Close", action: onClose)
                    Spacer()
                    Menu {
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task {
                                await account.signOut()
                                onClose()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More")
                }
                .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Google Drive")
                        .font(Theme.serif(40))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let email = account.email {
                        MetaText(email, size: 10.5).padding(.top, 6)
                    }
                    LazyVStack(spacing: 0) {
                        Hairline()
                        locationRow(.myDrive, icon: "folder")
                        locationRow(.sharedDrives, icon: "externaldrive")
                        locationRow(.sharedWithMe, icon: "person.2")
                    }
                    .padding(.top, 24)
                    Text("Closure only reads from your Drive. Files you import are copied to this iPhone and verified.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 16)
                }
                .padding(.horizontal, Theme.horizontalMargin)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func locationRow(_ location: GoogleDrive.Location, icon: String) -> some View {
        VStack(spacing: 0) {
            NavigationLink(value: location) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 24)
                    Text(location.title)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hairline()
        }
    }
}

/// One Drive folder (or My Drive, Shared with me, a shared drive): folders first, then
/// audio files. Other file types are hidden but counted.
private struct DriveFolderView: View {
    let location: GoogleDrive.Location
    @Environment(GoogleDriveAccount.self) private var account
    @Environment(DriveSelection.self) private var selection
    @State private var items: [GoogleDrive.File]?
    @State private var hiddenCount = 0
    @State private var error: String?

    /// The location itself as a pickable folder, when it is one.
    private var currentFolder: GoogleDrive.File? {
        switch location {
        case let .folder(id, name), let .sharedDrive(id, name):
            return GoogleDrive.File(id: id, name: name, mimeType: GoogleDrive.folderMimeType)
        default:
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Back")
                VStack(alignment: .leading, spacing: 0) {
                    Text(location.title)
                        .font(Theme.serif(32))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    if let folder = currentFolder {
                        TextAction(title: selection.contains(folder) ? "Deselect Folder" : "Select Folder",
                                   systemImage: selection.contains(folder) ? "checkmark.circle.fill" : "circle") {
                            selection.toggle(folder)
                        }
                        .padding(.top, 4)
                    }
                    content.padding(.top, 16)
                }
                .padding(.horizontal, Theme.horizontalMargin)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(alignment: .leading, spacing: 12) {
                Text(error)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                TextAction(title: "Try Again", systemImage: "arrow.clockwise") { Task { await load() } }
            }
        } else if let items {
            if items.isEmpty {
                Text("No folders or audio files here.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
            } else {
                LazyVStack(spacing: 0) {
                    Hairline()
                    ForEach(items) { item in
                        row(item)
                        Hairline()
                    }
                }
            }
            if hiddenCount > 0 {
                MetaText("\(hiddenCount) other file\(hiddenCount == 1 ? "" : "s") hidden", size: 10)
                    .padding(.top, 12)
            }
        } else {
            ProgressView().tint(Theme.ink).frame(maxWidth: .infinity).padding(.top, 24)
        }
    }

    @ViewBuilder
    private func row(_ item: GoogleDrive.File) -> some View {
        let selected = selection.contains(item)
        HStack(spacing: 12) {
            Button { selection.toggle(item) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Theme.ink : Theme.muted.opacity(0.6))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Deselect \(item.name)" : "Select \(item.name)")

            if item.isFolder {
                NavigationLink(value: destination(for: item)) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(Theme.ink)
                        Text(item.name).font(.system(size: 16)).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button { selection.toggle(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(Theme.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 16)).foregroundStyle(Theme.ink).lineLimit(1)
                            if item.byteCount > 0 {
                                MetaText(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file), size: 9.5, tracking: 0.8)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func destination(for item: GoogleDrive.File) -> GoogleDrive.Location {
        if case .sharedDrives = location { return .sharedDrive(id: item.id, name: item.name) }
        return .folder(id: item.id, name: item.name)
    }

    private func load() async {
        error = nil
#if DEBUG
        if let demo = DriveDemo.items(for: location) {
            items = demo.filter(\.isBrowsable)
            hiddenCount = demo.count - (items?.count ?? 0)
            return
        }
#endif
        do {
            let all = try await account.client().list(location)
            items = all.filter(\.isBrowsable)
            hiddenCount = all.count - (items?.count ?? 0)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#if DEBUG
/// -ClosureDriveDemo: canned Drive contents, to check the browser layout in the simulator.
enum DriveDemo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-ClosureDriveDemo") }

    static func items(for location: GoogleDrive.Location) -> [GoogleDrive.File]? {
        guard isOn else { return nil }
        let folder = GoogleDrive.folderMimeType
        switch location {
        case .myDrive:
            return [.init(id: "m", name: "Music", mimeType: folder), .init(id: "c", name: "Concerts 2019", mimeType: folder),
                    .init(id: "w", name: "Work", mimeType: folder),
                    .init(id: "t", name: "Demo take.wav", mimeType: "audio/wav", size: "48231544"),
                    .init(id: "p", name: "Brochure.pdf", mimeType: "application/pdf", size: "38000")]
        case .folder(_, "Music"):
            return [.init(id: "a1", name: "Low Light (Deluxe Edition)", mimeType: folder),
                    .init(id: "a2", name: "Paper Rooms", mimeType: folder),
                    .init(id: "a3", name: "Music for the Hours Between Midnight and Morning", mimeType: folder),
                    .init(id: "f1", name: "01 Arrival.flac", mimeType: "audio/flac", size: "31457280"),
                    .init(id: "f2", name: "02 Night Drive.flac", mimeType: "audio/flac", size: "34603008"),
                    .init(id: "x", name: "cover.jpg", mimeType: "image/jpeg", size: "200000")]
        case .sharedDrives:
            return [.init(id: "d1", name: "Band Archive", mimeType: folder)]
        default:
            return []
        }
    }
}
#endif
