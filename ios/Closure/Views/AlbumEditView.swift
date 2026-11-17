import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Edit an album's title, artist, year and cover. Changes are saved in the library
/// database only; the files and their tags stay as they are, and "Restore Original"
/// brings the tags back.
struct AlbumEditView: View {
    let album: Album
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var year: String
    /// A newly chosen cover, not saved yet.
    @State private var newCover: Data?
    @State private var newCoverImage: UIImage?
    @State private var removeCover = false
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var confirmingRestore = false
    @State private var saving = false

    /// What the tags say; shown as placeholders and used to tell real edits apart.
    private let original: Album.Original

    init(album: Album) {
        self.album = album
        let original = album.original ?? Album.Original(title: album.title, artist: album.artist, year: album.year)
        self.original = original
        _title = State(initialValue: album.title)
        _artist = State(initialValue: album.artist)
        _year = State(initialValue: album.year.map(String.init) ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                VStack(alignment: .leading, spacing: 0) {
                    Text("Edit Album")
                        .font(Theme.serif(32))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Changes stay in Closure. Your files are not changed.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 4)

                    coverSection.padding(.top, 24)

                    field("Title", text: $title, placeholder: original.title)
                        .padding(.top, 28)
                    field("Artist", text: $artist, placeholder: original.artist)
                        .padding(.top, 20)
                    field("Year", text: $year, placeholder: original.year.map(String.init) ?? "Unknown", keyboard: .numberPad)
                        .padding(.top, 20)

                    if album.isEdited || album.artworkOverride != nil {
                        TextAction(title: "Restore Original", systemImage: "arrow.uturn.backward") { confirmingRestore = true }
                            .padding(.top, 28)
                    }
                }
                .padding(.horizontal, Theme.horizontalMargin)
            }
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper.ignoresSafeArea())
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { useCover(data) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { useCover(data) }
        }
        .confirmationDialog("Restore the original album info?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore Original", role: .destructive) {
                Task {
                    await library.restoreOriginal(album.id)
                    dismiss()
                }
            }
        } message: {
            Text("The title, artist and year go back to the file tags, and a cover you chose is removed.")
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(.system(size: 17))
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 44)
            Spacer()
            Button("Save") { save() }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
                .disabled(saving)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.top, 8)
    }

    // MARK: - Cover

    private var coverSection: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let newCoverImage {
                    // Covers are square: the middle of the image is used, as shown here.
                    Image(uiImage: newCoverImage).resizable().scaledToFill()
                } else if removeCover {
                    ArtworkView(request: Album(id: album.id, title: album.title, artist: album.artist, tracks: album.tracks).artworkRequest,
                                title: album.title, pixelSize: 360)
                } else {
                    ArtworkView(request: album.artworkRequest, title: album.title, pixelSize: 360)
                }
            }
            .frame(width: 112, height: 112)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.ink.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 0) {
                MetaText("Cover", size: 10)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    actionLabel("Choose from Photos", systemImage: "photo")
                }
                .buttonStyle(.plain)
                Button { choosingFile = true } label: {
                    actionLabel("Choose from Files", systemImage: "folder")
                }
                .buttonStyle(.plain)
                if (album.artworkOverride != nil && !removeCover) || newCover != nil {
                    Button {
                        newCover = nil
                        newCoverImage = nil
                        removeCover = true
                    } label: {
                        actionLabel("Use Original Cover", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A text action without the underline, so three can stack quietly.
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 18)
            Text(title).font(.system(size: 15))
        }
        .foregroundStyle(Theme.ink)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    private func useCover(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        newCover = data
        newCoverImage = image
        removeCover = false
    }

    // MARK: - Fields

    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MetaText(label, size: 10)
            TextField(placeholder, text: text)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .numberPad ? .never : .words)
                .autocorrectionDisabled()
                .padding(.vertical, 6)
            Hairline()
        }
    }

    // MARK: - Saving

    private func save() {
        saving = true
        // A field equal to the tag value (or empty) is not an edit.
        func edit(_ value: String, _ tag: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == tag ? nil : trimmed
        }
        let yearValue = Int(year.trimmingCharacters(in: .whitespaces)).flatMap { (1000...2999).contains($0) ? $0 : nil }
        let newYear = yearValue == original.year ? nil : yearValue
        Task {
            await library.saveAlbumEdit(album.id, title: edit(title, original.title), artist: edit(artist, original.artist),
                                        year: newYear, cover: newCover, removeCover: removeCover)
            dismiss()
        }
    }
}
