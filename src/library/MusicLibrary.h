#pragma once

#include <JuceHeader.h>
#include "audio/TrackMetadata.h"
#include "metadata/MusicBrainzClient.h"

#include <functional>
#include <atomic>
#include <memory>
#include <optional>
#include <vector>

class MusicLibrary final
{
public:
    struct Track
    {
        juce::File file;
        juce::String title;
        juce::String artist;
        juce::String genre;
        juce::String musicBrainzRecordingId;
        int discNumber = 0;
        int trackNumber = 0;
        double durationSeconds = 0.0;
        std::shared_ptr<const juce::Image> artwork;

        bool isAvailable() const
        {
            return file.existsAsFile();
        }
    };

    struct Album
    {
        juce::String id;
        juce::String title;
        juce::String artist;
        juce::String genre;
        juce::String releaseDate;
        juce::String musicBrainzReleaseId;
        juce::String musicBrainzReleaseGroupId;
        juce::File sourceFolder;
        std::vector<Track> tracks;
        std::shared_ptr<const juce::Image> artwork;
        juce::File artworkCache;
        bool customArtwork = false;
        bool customTitle = false;
        bool customArtist = false;
        int metadataPending = 0;

        int availableTrackCount() const;
        bool hasAvailableTracks() const;
    };

    struct State
    {
        std::vector<Album> albums;
    };

    struct AddResult
    {
        bool success = false;
        juce::String albumId;
        juce::String error;
        int addedTracks = 0;
        int skippedTracks = 0;
    };

    using StateCallback = std::function<void(const State&)>;
    using AddCallback = std::function<void(AddResult)>;

    struct MetadataApplyResult
    {
        bool success = false;
        juce::String error;
        int updatedTracks = 0;
        bool artworkApplied = false;
    };

    using MetadataSearchCallback = MusicBrainzClient::SearchCallback;
    using MetadataApplyCallback = std::function<void(MetadataApplyResult)>;

    MusicLibrary();
    explicit MusicLibrary(const juce::File& storageDirectory);
    ~MusicLibrary();

    AddResult addAlbum(const juce::File& folder);
    void addAlbumAsync(const juce::File& folder, AddCallback callback);
    bool removeAlbum(const juce::String& albumId);
    bool renameAlbum(const juce::String& albumId,
                     const juce::String& title,
                     const juce::String& artist);
    bool setCustomArtwork(const juce::String& albumId, const juce::File& imageFile);
    void searchMetadataAsync(const juce::String& albumId, MetadataSearchCallback callback);
    void applyMetadataAsync(const juce::String& albumId,
                            const juce::String& releaseId,
                            MetadataApplyCallback callback);

    std::optional<Album> getAlbum(const juce::String& albumId) const;
    juce::Array<juce::File> getPlayableFiles(const juce::String& albumId) const;
    TrackMetadataPtr metadataForPlayback(const juce::File& file,
                                         const TrackMetadataPtr& fallback) const;
    State getState() const;
    void setStateCallback(StateCallback callback);

private:
    struct ScannedAlbum
    {
        Album album;
        std::vector<juce::File> metadataFiles;
        int skippedTracks = 0;
    };

    static juce::String defaultTitleFor(const juce::File& folder);
    static juce::String defaultArtist();

    static ScannedAlbum scanFolder(const juce::File& folder);
    AddResult commitScannedAlbum(ScannedAlbum scanned);
    void loadLibrary();
    bool saveLibrary() const;
    void scheduleMetadataRead(const juce::String& albumId, const juce::File& file);
    void metadataReady(const juce::String& albumId, TrackMetadata metadata);
    MetadataApplyResult applyMetadata(const juce::String& albumId,
                                      MusicBrainz::ReleaseMetadata metadata);
    bool saveArtworkToCache(const juce::String& albumId,
                            const juce::Image& image,
                            juce::File& destination) const;
    void notifyState() const;

    juce::File libraryFile;
    juce::File artworkDirectory;
    juce::ThreadPool scanThread { 1 };
    TrackMetadataReader metadataReader;
    std::unique_ptr<MusicBrainzClient> onlineMetadataClient;
    std::shared_ptr<std::atomic_bool> lifetime;

    mutable juce::CriticalSection stateLock;
    std::vector<Album> albums;
    StateCallback stateCallback;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(MusicLibrary)
};
