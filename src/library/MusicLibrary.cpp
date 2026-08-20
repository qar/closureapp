#include "MusicLibrary.h"
#include "audio/AudioFileFormats.h"

#include <algorithm>
#include <memory>

namespace
{
struct FilePathComparator
{
    int compareElements(const juce::File& first, const juce::File& second) const
    {
        return first.getFullPathName().compareIgnoreCase(second.getFullPathName());
    }
};

bool samePath(const juce::File& first, const juce::File& second)
{
    return first.getFullPathName().compareIgnoreCase(second.getFullPathName()) == 0;
}

bool trackOrder(const MusicLibrary::Track& first, const MusicLibrary::Track& second)
{
    if (first.discNumber != second.discNumber)
    {
        if (first.discNumber == 0)
            return false;
        if (second.discNumber == 0)
            return true;
        return first.discNumber < second.discNumber;
    }

    if (first.trackNumber != second.trackNumber)
    {
        if (first.trackNumber == 0)
            return false;
        if (second.trackNumber == 0)
            return true;
        return first.trackNumber < second.trackNumber;
    }

    return first.file.getFullPathName().compareIgnoreCase(second.file.getFullPathName()) < 0;
}

void sortTracks(MusicLibrary::Album& album)
{
    const auto hasCompleteTrackNumbers = std::all_of(album.tracks.begin(), album.tracks.end(),
                                                      [](const auto& track)
    {
        return track.trackNumber > 0;
    });

    if (hasCompleteTrackNumbers)
    {
        std::stable_sort(album.tracks.begin(), album.tracks.end(), trackOrder);
        return;
    }

    std::stable_sort(album.tracks.begin(), album.tracks.end(), [](const auto& first, const auto& second)
    {
        return first.file.getFullPathName().compareIgnoreCase(second.file.getFullPathName()) < 0;
    });
}

juce::String readAttribute(const juce::XmlElement& element, const char* name)
{
    return element.getStringAttribute(name).trim();
}
}

int MusicLibrary::Album::availableTrackCount() const
{
    return static_cast<int>(std::count_if(tracks.begin(), tracks.end(), [](const auto& track)
    {
        return track.isAvailable();
    }));
}

bool MusicLibrary::Album::hasAvailableTracks() const
{
    return std::any_of(tracks.begin(), tracks.end(), [](const auto& track)
    {
        return track.isAvailable();
    });
}

MusicLibrary::MusicLibrary()
    : MusicLibrary(juce::File::getSpecialLocation(juce::File::userApplicationDataDirectory)
                       .getChildFile("Closure"))
{
}

MusicLibrary::MusicLibrary(const juce::File& storageDirectory)
{
    lifetime = std::make_shared<std::atomic_bool>(true);
    libraryFile = storageDirectory.getChildFile("library.xml");
    artworkDirectory = storageDirectory.getChildFile("AlbumCovers");

    loadLibrary();

    State loadedState;
    {
        const juce::ScopedLock sl(stateLock);
        loadedState.albums = albums;
    }

    for (const auto& album : loadedState.albums)
        for (const auto& track : album.tracks)
            scheduleMetadataRead(album.id, track.file);
}

MusicLibrary::~MusicLibrary()
{
    lifetime->store(false);
    scanThread.removeAllJobs(true, 10000);
}

MusicLibrary::AddResult MusicLibrary::addAlbum(const juce::File& folder)
{
    AddResult result;
    if (!folder.isDirectory())
    {
        result.error = "The selected folder does not exist.";
        return result;
    }

    {
        const juce::ScopedLock sl(stateLock);
        const auto duplicate = std::any_of(albums.begin(), albums.end(), [&folder](const auto& album)
        {
            return samePath(album.sourceFolder, folder);
        });

        if (duplicate)
        {
            result.error = "This folder is already in the library.";
            return result;
        }
    }

    return commitScannedAlbum(scanFolder(folder));
}

void MusicLibrary::addAlbumAsync(const juce::File& folder, AddCallback callback)
{
    if (!callback)
        return;

    if (!folder.isDirectory())
    {
        juce::MessageManager::callAsync([callbackForMessage = std::move(callback)]() mutable
        {
            AddResult result;
            result.error = "The selected folder does not exist.";
            callbackForMessage(std::move(result));
        });
        return;
    }

    class ScanJob final : public juce::ThreadPoolJob
    {
    public:
        ScanJob(MusicLibrary& ownerIn,
                juce::File folderIn,
                AddCallback callbackIn,
                std::shared_ptr<std::atomic_bool> lifetimeIn)
            : ThreadPoolJob("Scan album folder"),
              owner(ownerIn),
              folder(std::move(folderIn)),
              callback(std::move(callbackIn)),
              lifetime(std::move(lifetimeIn))
        {
        }

        JobStatus runJob() override
        {
            auto scannedAlbum = MusicLibrary::scanFolder(folder);
            auto ownerPointer = &owner;
            auto messageCallback = std::move(callback);
            auto lifetimeCopy = lifetime;

            juce::MessageManager::callAsync(
                [ownerPointer,
                 callbackForMessage = std::move(messageCallback),
                 lifetimeCopy,
                 scanned = std::move(scannedAlbum)]() mutable
                {
                    if (!lifetimeCopy->load())
                        return;

                    auto result = ownerPointer->commitScannedAlbum(std::move(scanned));
                    if (callbackForMessage)
                        callbackForMessage(std::move(result));
                });

            return jobHasFinished;
        }

    private:
        MusicLibrary& owner;
        juce::File folder;
        AddCallback callback;
        std::shared_ptr<std::atomic_bool> lifetime;
    };

    scanThread.addJob(new ScanJob(*this, folder, std::move(callback), lifetime), true);
}

MusicLibrary::AddResult MusicLibrary::commitScannedAlbum(ScannedAlbum scanned)
{
    AddResult result;
    result.skippedTracks = scanned.skippedTracks;

    {
        const juce::ScopedLock sl(stateLock);
        const auto duplicate = std::any_of(albums.begin(), albums.end(),
                                           [&scanned](const auto& album)
        {
            return samePath(album.sourceFolder, scanned.album.sourceFolder);
        });

        if (duplicate)
        {
            result.error = "This folder is already in the library.";
            return result;
        }
    }

    if (scanned.album.tracks.empty())
    {
        result.error = "No playable audio files were found in the selected folder.";
        return result;
    }

    result.success = true;
    result.albumId = scanned.album.id;
    result.addedTracks = static_cast<int>(scanned.album.tracks.size());

    {
        const juce::ScopedLock sl(stateLock);
        scanned.album.metadataPending = static_cast<int>(scanned.album.tracks.size());
        albums.push_back(std::move(scanned.album));
    }

    if (!saveLibrary())
    {
        const juce::ScopedLock sl(stateLock);
        albums.erase(std::remove_if(albums.begin(), albums.end(), [&result](const auto& album)
        {
            return album.id == result.albumId;
        }), albums.end());
        result.success = false;
        result.error = "The library could not be saved.";
        return result;
    }

    for (const auto& file : scanned.metadataFiles)
        scheduleMetadataRead(result.albumId, file);

    notifyState();
    return result;
}

bool MusicLibrary::removeAlbum(const juce::String& albumId)
{
    juce::File artworkCache;
    Album removedAlbum;
    size_t removedIndex = 0;
    bool removed = false;

    {
        const juce::ScopedLock sl(stateLock);
        const auto it = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });

        if (it != albums.end())
        {
            artworkCache = it->artworkCache;
            removedIndex = static_cast<size_t>(std::distance(albums.begin(), it));
            removedAlbum = *it;
            albums.erase(it);
            removed = true;
        }
    }

    if (!removed)
        return false;

    if (!saveLibrary())
    {
        const juce::ScopedLock sl(stateLock);
        albums.insert(albums.begin() + static_cast<ptrdiff_t>(removedIndex), std::move(removedAlbum));
        return false;
    }

    if (artworkCache.existsAsFile())
        artworkCache.deleteFile();

    notifyState();
    return true;
}

bool MusicLibrary::renameAlbum(const juce::String& albumId,
                               const juce::String& title,
                               const juce::String& artist)
{
    const auto cleanTitle = title.trim();
    const auto cleanArtist = artist.trim();
    if (cleanTitle.isEmpty() || cleanArtist.isEmpty())
        return false;

    juce::String oldTitle;
    juce::String oldArtist;
    {
        const juce::ScopedLock sl(stateLock);
        const auto it = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });

        if (it == albums.end())
            return false;

        oldTitle = it->title;
        oldArtist = it->artist;
        it->title = cleanTitle;
        it->artist = cleanArtist;
    }

    if (!saveLibrary())
    {
        const juce::ScopedLock sl(stateLock);
        const auto it = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });
        if (it != albums.end())
        {
            it->title = oldTitle;
            it->artist = oldArtist;
        }
        return false;
    }

    notifyState();
    return true;
}

bool MusicLibrary::setCustomArtwork(const juce::String& albumId,
                                    const juce::File& imageFile)
{
    {
        const juce::ScopedLock sl(stateLock);
        const auto exists = std::any_of(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });
        if (!exists)
            return false;
    }

    const auto image = juce::ImageFileFormat::loadFrom(imageFile);
    if (!image.isValid())
        return false;

    juce::File destination;
    if (!saveArtworkToCache(albumId, image, destination))
        return false;

    std::shared_ptr<const juce::Image> oldArtwork;
    juce::File oldArtworkCache;
    bool oldCustomArtwork = false;
    {
        const juce::ScopedLock sl(stateLock);
        const auto it = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });

        if (it == albums.end())
            return false;

        oldArtwork = it->artwork;
        oldArtworkCache = it->artworkCache;
        oldCustomArtwork = it->customArtwork;
        it->artwork = std::make_shared<const juce::Image>(image);
        it->artworkCache = destination;
        it->customArtwork = true;
    }

    if (!saveLibrary())
    {
        const juce::ScopedLock sl(stateLock);
        const auto it = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });
        if (it != albums.end())
        {
            it->artwork = std::move(oldArtwork);
            it->artworkCache = oldArtworkCache;
            it->customArtwork = oldCustomArtwork;
        }
        return false;
    }

    notifyState();
    return true;
}

std::optional<MusicLibrary::Album> MusicLibrary::getAlbum(const juce::String& albumId) const
{
    const juce::ScopedLock sl(stateLock);
    const auto it = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
    {
        return album.id == albumId;
    });

    if (it == albums.end())
        return std::nullopt;

    return *it;
}

juce::Array<juce::File> MusicLibrary::getPlayableFiles(const juce::String& albumId) const
{
    juce::Array<juce::File> files;
    const auto album = getAlbum(albumId);
    if (!album.has_value())
        return files;

    for (const auto& track : album->tracks)
    {
        if (track.isAvailable())
            files.add(track.file);
    }

    return files;
}

MusicLibrary::State MusicLibrary::getState() const
{
    const juce::ScopedLock sl(stateLock);
    State state;
    state.albums = albums;
    return state;
}

void MusicLibrary::setStateCallback(StateCallback callback)
{
    stateCallback = std::move(callback);
}

juce::String MusicLibrary::defaultTitleFor(const juce::File& folder)
{
    const auto title = folder.getFileName().trim();
    return title.isNotEmpty() ? title : "Untitled Album";
}

juce::String MusicLibrary::defaultArtist()
{
    return "Unknown Artist";
}

MusicLibrary::ScannedAlbum MusicLibrary::scanFolder(const juce::File& folder)
{
    ScannedAlbum result;
    result.album.id = juce::Uuid().toString();
    result.album.title = defaultTitleFor(folder);
    result.album.artist = defaultArtist();
    result.album.sourceFolder = folder;

    juce::Array<juce::File> children;
    folder.findChildFiles(children, juce::File::findFiles, true, "*");
    FilePathComparator comparator;
    children.sort(comparator, true);

    juce::AudioFormatManager formatManager;
    formatManager.registerBasicFormats();

    for (const auto& child : children)
    {
        if (!AudioFileFormats::isSupported(child))
            continue;

        std::unique_ptr<juce::AudioFormatReader> reader(formatManager.createReaderFor(child));
        if (reader == nullptr)
        {
            ++result.skippedTracks;
            continue;
        }

        const auto fallback = TrackMetadataUtil::fallbackForFile(child);
        Track track;
        track.file = child;
        track.title = fallback.title;
        track.artist = fallback.artist;
        track.durationSeconds = reader->sampleRate > 0.0
                              ? static_cast<double>(reader->lengthInSamples) / reader->sampleRate
                              : 0.0;
        result.album.tracks.push_back(std::move(track));
        result.metadataFiles.push_back(child);
    }

    sortTracks(result.album);

    return result;
}

void MusicLibrary::loadLibrary()
{
    if (!libraryFile.existsAsFile())
        return;

    const auto document = juce::XmlDocument::parse(libraryFile);
    if (document == nullptr || !document->hasTagName("library"))
    {
        libraryFile.copyFileTo(libraryFile.withFileExtension("xml.corrupt"));
        return;
    }

    std::vector<Album> loaded;
    for (auto* albumElement = document->getFirstChildElement();
         albumElement != nullptr;
         albumElement = albumElement->getNextElement())
    {
        if (!albumElement->hasTagName("album"))
            continue;

        Album album;
        album.id = readAttribute(*albumElement, "id");
        album.title = readAttribute(*albumElement, "title");
        album.artist = readAttribute(*albumElement, "artist");
        album.sourceFolder = juce::File(readAttribute(*albumElement, "sourceFolder"));
        const auto storedCustomArtwork = albumElement->getBoolAttribute("customArtwork", false);
        album.artworkCache = juce::File(readAttribute(*albumElement, "artworkCache"));

        if (album.id.isEmpty() || album.title.isEmpty())
            continue;

        if (album.artworkCache.existsAsFile())
        {
            const auto image = juce::ImageFileFormat::loadFrom(album.artworkCache);
            if (image.isValid())
            {
                album.artwork = std::make_shared<const juce::Image>(image);
                album.customArtwork = storedCustomArtwork;
            }
        }

        for (auto* trackElement = albumElement->getFirstChildElement();
             trackElement != nullptr;
             trackElement = trackElement->getNextElement())
        {
            if (!trackElement->hasTagName("track"))
                continue;

            Track track;
            track.file = juce::File(readAttribute(*trackElement, "path"));
            track.title = readAttribute(*trackElement, "title");
            track.artist = readAttribute(*trackElement, "artist");
            track.discNumber = trackElement->getIntAttribute("discNumber", 0);
            track.trackNumber = trackElement->getIntAttribute("trackNumber", 0);
            track.durationSeconds = trackElement->getDoubleAttribute("durationSeconds", 0.0);

            if (track.file != juce::File{})
                album.tracks.push_back(std::move(track));
        }

        if (!album.tracks.empty())
        {
            sortTracks(album);
            album.metadataPending = static_cast<int>(album.tracks.size());
            loaded.push_back(std::move(album));
        }
    }

    const juce::ScopedLock sl(stateLock);
    albums = std::move(loaded);
}

bool MusicLibrary::saveLibrary() const
{
    const auto parent = libraryFile.getParentDirectory();
    if (!parent.createDirectory() && !parent.isDirectory())
        return false;

    State state = getState();
    auto document = std::make_unique<juce::XmlElement>("library");
    document->setAttribute("version", 1);

    for (const auto& album : state.albums)
    {
        auto* albumElement = document->createNewChildElement("album");
        albumElement->setAttribute("id", album.id);
        albumElement->setAttribute("title", album.title);
        albumElement->setAttribute("artist", album.artist);
        albumElement->setAttribute("sourceFolder", album.sourceFolder.getFullPathName());
        albumElement->setAttribute("customArtwork", album.customArtwork);
        albumElement->setAttribute("artworkCache", album.artworkCache.getFullPathName());

        for (const auto& track : album.tracks)
        {
            auto* trackElement = albumElement->createNewChildElement("track");
            trackElement->setAttribute("path", track.file.getFullPathName());
            trackElement->setAttribute("title", track.title);
            trackElement->setAttribute("artist", track.artist);
            trackElement->setAttribute("discNumber", track.discNumber);
            trackElement->setAttribute("trackNumber", track.trackNumber);
            trackElement->setAttribute("durationSeconds", track.durationSeconds);
        }
    }

    const auto temporaryFile = libraryFile.getSiblingFile(libraryFile.getFileName() + ".tmp");
    if (!temporaryFile.replaceWithText(document->toString(), false, false, "\n"))
        return false;

    if (libraryFile.existsAsFile())
        return temporaryFile.replaceFileIn(libraryFile);

    return temporaryFile.moveFileTo(libraryFile);
}

void MusicLibrary::scheduleMetadataRead(const juce::String& albumId,
                                        const juce::File& file)
{
    if (!file.existsAsFile())
    {
        const juce::ScopedLock sl(stateLock);
        const auto albumIt = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });
        if (albumIt != albums.end() && albumIt->metadataPending > 0)
            --albumIt->metadataPending;
        return;
    }

    metadataReader.readAsync(file, [this, albumId](TrackMetadata metadata)
    {
        metadataReady(albumId, std::move(metadata));
    });
}

void MusicLibrary::metadataReady(const juce::String& albumId, TrackMetadata metadata)
{
    bool changed = false;
    juce::Image artworkToCache;

    {
        const juce::ScopedLock sl(stateLock);
        const auto albumIt = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
        {
            return album.id == albumId;
        });

        if (albumIt == albums.end())
            return;

        auto trackIt = std::find_if(albumIt->tracks.begin(), albumIt->tracks.end(),
                                    [&metadata](const auto& track)
        {
            return samePath(track.file, metadata.file);
        });

        if (trackIt == albumIt->tracks.end())
            return;

        const auto fallback = TrackMetadataUtil::fallbackForFile(metadata.file);
        if (metadata.title.isNotEmpty() && (metadata.title != fallback.title || trackIt->title.isEmpty()))
            trackIt->title = metadata.title;
        if (metadata.artist.isNotEmpty() && (metadata.artist != fallback.artist || trackIt->artist.isEmpty()))
            trackIt->artist = metadata.artist;
        if (metadata.discNumber > 0)
            trackIt->discNumber = metadata.discNumber;
        if (metadata.trackNumber > 0)
            trackIt->trackNumber = metadata.trackNumber;
        if (metadata.durationSeconds > 0.0)
            trackIt->durationSeconds = metadata.durationSeconds;

        if (albumIt->artist == defaultArtist())
        {
            const auto artist = metadata.albumArtist.isNotEmpty() ? metadata.albumArtist : metadata.artist;
            if (artist.isNotEmpty() && artist != defaultArtist())
                albumIt->artist = artist;
        }

        if (albumIt->title == defaultTitleFor(albumIt->sourceFolder)
            && metadata.album.isNotEmpty()
            && metadata.album != "Local Files")
            albumIt->title = metadata.album;

        if (metadata.hasArtwork())
            trackIt->artwork = metadata.artwork;

        if (albumIt->metadataPending > 0)
            --albumIt->metadataPending;

        sortTracks(*albumIt);

        if (!albumIt->customArtwork && albumIt->metadataPending == 0)
        {
            const auto artworkTrack = std::find_if(albumIt->tracks.begin(), albumIt->tracks.end(),
                                                   [](const auto& track)
            {
                return track.artwork != nullptr && track.artwork->isValid();
            });

            if (artworkTrack != albumIt->tracks.end()
                && (albumIt->artwork == nullptr || albumIt->artworkCache == juce::File{}))
            {
                albumIt->artwork = artworkTrack->artwork;
                artworkToCache = *artworkTrack->artwork;
            }
        }

        changed = true;
    }

    if (!artworkToCache.isNull())
    {
        juce::File destination;
        if (saveArtworkToCache(albumId, artworkToCache, destination))
        {
            const juce::ScopedLock sl(stateLock);
            const auto albumIt = std::find_if(albums.begin(), albums.end(), [&albumId](const auto& album)
            {
                return album.id == albumId;
            });

            if (albumIt != albums.end() && !albumIt->customArtwork)
                albumIt->artworkCache = destination;
        }
    }

    if (changed)
    {
        saveLibrary();
        notifyState();
    }
}

bool MusicLibrary::saveArtworkToCache(const juce::String& albumId,
                                      const juce::Image& image,
                                      juce::File& destination) const
{
    if (!image.isValid() || albumId.isEmpty())
        return false;

    if (!artworkDirectory.createDirectory() && !artworkDirectory.isDirectory())
        return false;

    destination = artworkDirectory.getChildFile(albumId + ".png");
    auto output = destination.createOutputStream();
    if (output == nullptr || !output->openedOk())
        return false;

    juce::PNGImageFormat format;
    const auto thumbnail = image.getWidth() > 512 || image.getHeight() > 512
                         ? image.rescaled(512, 512, juce::Graphics::highResamplingQuality)
                         : image;
    return format.writeImageToStream(thumbnail, *output);
}

void MusicLibrary::notifyState() const
{
    if (stateCallback)
    {
        const auto state = getState();
        stateCallback(state);
    }
}
