#pragma once

#include <JuceHeader.h>
#include "library/MusicLibrary.h"

#include <functional>
#include <memory>
#include <optional>

class AlbumBrowser final : public juce::Component
{
public:
    using AlbumCallback = std::function<void(const juce::String&)>;
    using TrackCallback = std::function<void(const juce::String&, const juce::File&)>;

    /** The browser extends this far beyond the column it is aligned to, so album
        covers line up with the column edges while their shadows stay unclipped. */
    static constexpr int contentInset = 12;

    AlbumBrowser();
    ~AlbumBrowser() override;

    void paint(juce::Graphics& g) override;
    void resized() override;

    void setState(const MusicLibrary::State& state);
    void setPlaybackState(const juce::String& playlistId, const juce::String& filePath);
    void showAlbumList();
    bool isShowingDetails() const { return selectedAlbumId.has_value(); }

    void setPlayAlbumCallback(AlbumCallback callback);
    void setPlayTrackCallback(TrackCallback callback);
    void setViewChangedCallback(std::function<void()> callback);
    void setAddToQueueCallback(AlbumCallback callback);
    void setChooseArtworkCallback(AlbumCallback callback);
    void setEditAlbumCallback(AlbumCallback callback);
    void setRemoveAlbumCallback(AlbumCallback callback);
    void setMatchMetadataCallback(AlbumCallback callback);
    void setMetadataMatching(bool matching);

private:
    class GridComponent;
    class TrackListModel;

    void showAlbumDetails(const juce::String& albumId);
    void playTrackAt(int rowNumber) const;
    void showMoreMenu();
    void refreshSelectedAlbum();
    const MusicLibrary::Album* selectedAlbum() const;
    bool isCurrentTrack(const MusicLibrary::Track& track) const;
    void drawArtwork(juce::Graphics& g,
                    juce::Rectangle<float> bounds,
                    const MusicLibrary::Album& album) const;

    MusicLibrary::State currentState;
    std::optional<juce::String> selectedAlbumId;
    juce::String playbackPlaylistId;
    juce::String playbackFilePath;

    class GridViewport final : public juce::Viewport
    {
    public:
        std::function<void()> onVisibleAreaChanged;

        void visibleAreaChanged(const juce::Rectangle<int>&) override
        {
            if (onVisibleAreaChanged)
                onVisibleAreaChanged();
        }
    };

    void layoutGrid();

    GridViewport gridViewport;
    int laidOutGridWidth = -1;
    std::unique_ptr<GridComponent> gridComponent;

    juce::TextButton backButton { "Albums" };
    juce::TextButton playButton { "Play album" };
    juce::TextButton addToQueueButton { "Add to queue" };
    juce::TextButton artworkButton { "Change cover" };
    juce::TextButton editButton { "Edit details" };
    juce::TextButton removeButton { "Remove" };
    juce::TextButton moreButton { "More" };
    juce::Label detailTitle;
    juce::Label detailArtist;
    juce::Label detailInfo;
    juce::ListBox trackList;
    std::unique_ptr<TrackListModel> trackModel;
    juce::Rectangle<float> detailArtworkBounds;

    AlbumCallback playAlbumCallback;
    TrackCallback playTrackCallback;
    std::function<void()> viewChangedCallback;
    AlbumCallback addToQueueCallback;
    AlbumCallback chooseArtworkCallback;
    AlbumCallback editAlbumCallback;
    AlbumCallback removeAlbumCallback;
    AlbumCallback matchMetadataCallback;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(AlbumBrowser)
};
