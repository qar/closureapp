#pragma once

#include <JuceHeader.h>
#include "audio/AudioEngine.h"
#include "lyrics/LyricsClient.h"
#include "library/MusicLibrary.h"
#include "ui/AlbumBrowser.h"
#include "ui/GlassLookAndFeel.h"

#include <array>
#include <map>
#include <set>
#include <string>

class PlayerPanel final : public juce::Component,
                          private juce::ListBoxModel,
                          private juce::Timer,
                          private juce::ChangeListener
{
public:
    PlayerPanel(AudioEngine& engine, MusicLibrary& library);
    ~PlayerPanel() override;

    void paint(juce::Graphics& g) override;
    void resized() override;
    void mouseUp(const juce::MouseEvent& event) override;

    void applyState(const AudioEngine::State& state);
    void applyLibraryState(const MusicLibrary::State& state);

private:
    enum class VisualMode
    {
        artwork,
        spectrum,
        lyrics
    };

    void openFileChooser();
    void openAlbumChooser();
    void chooseAlbumArtwork(const juce::String& albumId);
    void editAlbum(const juce::String& albumId);
    void matchAlbumMetadata(const juce::String& albumId);
    void setMetadataMatching(bool matching);
    void playAlbum(const juce::String& albumId, int startTrackIndex = 0);
    void playAlbumTrack(const juce::String& albumId, const juce::File& file);
    void addAlbumToQueue(const juce::String& albumId);
    void removeAlbum(const juce::String& albumId);
    void showAlbumView();
    void showQueueView();
    void seekFromSlider();
    void rebuildPlaylistRows();
    void updateControlLabels();
    void updateSpectrum();
    void updateCurrentTrackDisplay();
    void scheduleLyricsFetch(const TrackMetadataPtr& metadata);
    void cycleVisualMode();
    void changeListenerCallback(juce::ChangeBroadcaster* source) override;
    void timerCallback() override;

    TrackMetadataPtr metadataAt(int index) const;
    TrackMetadataPtr metadataForFile(const juce::File& file,
                                     const TrackMetadataPtr& fallback) const;
    juce::String titleAt(int index) const;
    juce::String artistAt(int index) const;
    juce::String albumAt(int index) const;
    double durationAt(int index) const;

    void drawArtwork(juce::Graphics& g,
                     juce::Rectangle<float> bounds,
                     const TrackMetadataPtr& metadata,
                     const juce::String& fallbackKey) const;
    void drawSpectrum(juce::Graphics& g,
                      juce::Rectangle<float> bounds,
                      const TrackMetadataPtr& metadata,
                      const juce::String& fallbackKey) const;
    void drawLyrics(juce::Graphics& g,
                    juce::Rectangle<float> bounds,
                    const TrackMetadataPtr& metadata) const;

    int getNumRows() override;
    void paintListBoxItem(int rowNumber,
                          juce::Graphics& g,
                          int width,
                          int height,
                          bool rowIsSelected) override;
    void listBoxItemClicked(int rowNumber, const juce::MouseEvent&) override;

    AudioEngine& audioEngine;
    MusicLibrary& musicLibrary;
    GlassLookAndFeel lookAndFeel;
    AlbumBrowser albumBrowser;

    juce::Label playlistInfoLabel;
    juce::Label currentTitleLabel;
    juce::Label currentArtistLabel;
    juce::Label currentAlbumLabel;
    juce::Label emptyStateLabel;
    juce::Label elapsedTimeLabel;
    juce::Label durationTimeLabel;
    juce::Label volumeLabel;

    juce::ListBox playlistList;
    juce::TextButton addButton { "Add music" };
    juce::TextButton addAlbumButton { "Add album" };
    juce::TextButton clearButton { "Clear" };
    juce::TabbedButtonBar viewTabs { juce::TabbedButtonBar::TabsAtTop };
    juce::TextButton backToAlbumsButton { "Back to albums" };
    juce::DrawableButton previousButton { "Previous track", juce::DrawableButton::ImageFitted };
    juce::DrawableButton playButton { "Play", juce::DrawableButton::ImageFitted };
    juce::DrawableButton stopButton { "Stop", juce::DrawableButton::ImageFitted };
    juce::DrawableButton nextButton { "Next track", juce::DrawableButton::ImageFitted };
    juce::DrawableButton repeatButton { "Repeat mode", juce::DrawableButton::ImageFitted };
    juce::TextButton gaplessButton { "Gapless" };
    juce::Slider positionSlider;
    juce::Slider volumeSlider;

    // 4096 samples reaches the sub-20 Hz region while retaining the full Nyquist range.
    static constexpr int spectrumOrder = 12;
    static constexpr int spectrumSize = 1 << spectrumOrder;
    static constexpr int spectrumBarCount = 48;
    static constexpr int spectrumReadSize = 2048;

    bool isSeeking = false;
    VisualMode visualMode = VisualMode::artwork;
    bool showingAlbums = false;
    AudioEngine::State currentState;
    MusicLibrary::State libraryState;
    TrackMetadataPtr currentPlaybackMetadata;
    double lyricsPositionBaseSeconds = 0.0;
    double lyricsPositionTimestampMs = 0.0;
    LyricsClient lyricsClient;
    std::map<std::string, Lyrics::Result> fetchedLyrics;
    std::map<std::string, juce::String> fetchedLyricsKeys;
    std::map<std::string, juce::String> lyricsFetchKeys;
    std::map<std::string, int64_t> lyricsRetryAfterMs;
    std::set<std::string> lyricsFetchesInFlight;
    std::vector<int> visibleTrackIndices;
    juce::dsp::FFT spectrumFft;
    juce::dsp::WindowingFunction<float> spectrumWindow;
    std::array<float, spectrumSize> spectrumHistory {};
    std::array<float, spectrumSize * 2> fftData {};
    std::array<float, spectrumBarCount> spectrumLevels {};
    std::array<float, spectrumReadSize> analysisReadBuffer {};

    juce::Rectangle<int> panelBounds;
    juce::Rectangle<int> nowPlayingBounds;
    juce::Rectangle<int> playlistBounds;
    juce::Rectangle<int> transportBounds;
    juce::Rectangle<int> spectrumBounds;
    juce::Rectangle<int> artworkBounds;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PlayerPanel)
};
