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

    AlbumBrowser();
    ~AlbumBrowser() override;

    void paint(juce::Graphics& g) override;
    void resized() override;

    void setState(const MusicLibrary::State& state);
    void showAlbumList();

    void setPlayAlbumCallback(AlbumCallback callback);
    void setAddToQueueCallback(AlbumCallback callback);
    void setChooseArtworkCallback(AlbumCallback callback);
    void setEditAlbumCallback(AlbumCallback callback);
    void setRemoveAlbumCallback(AlbumCallback callback);

private:
    class GridComponent;
    class TrackListModel;

    void showAlbumDetails(const juce::String& albumId);
    void refreshSelectedAlbum();
    const MusicLibrary::Album* selectedAlbum() const;
    void drawArtwork(juce::Graphics& g,
                    juce::Rectangle<float> bounds,
                    const MusicLibrary::Album& album) const;

    MusicLibrary::State currentState;
    std::optional<juce::String> selectedAlbumId;

    juce::Viewport gridViewport;
    std::unique_ptr<GridComponent> gridComponent;

    juce::TextButton backButton { "Albums" };
    juce::TextButton playButton { "Play album" };
    juce::TextButton addToQueueButton { "Add to queue" };
    juce::TextButton artworkButton { "Change cover" };
    juce::TextButton editButton { "Edit details" };
    juce::TextButton removeButton { "Remove" };
    juce::Label detailTitle;
    juce::Label detailArtist;
    juce::Label detailInfo;
    juce::ListBox trackList;
    std::unique_ptr<TrackListModel> trackModel;
    juce::Rectangle<float> detailArtworkBounds;

    AlbumCallback playAlbumCallback;
    AlbumCallback addToQueueCallback;
    AlbumCallback chooseArtworkCallback;
    AlbumCallback editAlbumCallback;
    AlbumCallback removeAlbumCallback;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(AlbumBrowser)
};
