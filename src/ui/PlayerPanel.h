#pragma once

#include <JuceHeader.h>
#include "audio/AudioEngine.h"
#include "ui/GlassLookAndFeel.h"

class PlayerPanel final : public juce::Component,
                          private juce::ListBoxModel
{
public:
    explicit PlayerPanel(AudioEngine& engine);
    ~PlayerPanel() override;

    void paint(juce::Graphics& g) override;
    void resized() override;

    void applyState(const AudioEngine::State& state);

private:
    void openFileChooser();
    void seekFromSlider();
    void rebuildPlaylistRows();
    void updateControlLabels();

    TrackMetadataPtr metadataAt(int index) const;
    juce::String titleAt(int index) const;
    juce::String artistAt(int index) const;
    juce::String albumAt(int index) const;
    double durationAt(int index) const;
    juce::String repeatModeText() const;

    void drawArtwork(juce::Graphics& g,
                    juce::Rectangle<float> bounds,
                    const TrackMetadataPtr& metadata,
                    const juce::String& fallbackKey) const;
    void drawCard(juce::Graphics& g, juce::Rectangle<float> bounds) const;
    void drawTransportSurface(juce::Graphics& g, juce::Rectangle<float> bounds) const;

    int getNumRows() override;
    void paintListBoxItem(int rowNumber,
                          juce::Graphics& g,
                          int width,
                          int height,
                          bool rowIsSelected) override;
    void listBoxItemClicked(int rowNumber, const juce::MouseEvent&) override;

    AudioEngine& audioEngine;
    GlassLookAndFeel lookAndFeel;

    juce::Label appTitleLabel;
    juce::Label appSubtitleLabel;
    juce::Label playlistLabel;
    juce::Label playlistInfoLabel;
    juce::Label currentTitleLabel;
    juce::Label currentArtistLabel;
    juce::Label currentAlbumLabel;
    juce::Label emptyStateLabel;
    juce::Label timeLabel;
    juce::Label volumeLabel;

    juce::ListBox playlistList;
    juce::TextButton addButton { "Add music" };
    juce::TextButton clearButton { "Clear" };
    juce::TextButton previousButton { "Prev" };
    juce::TextButton playButton { "Play" };
    juce::TextButton stopButton { "Stop" };
    juce::TextButton nextButton { "Next" };
    juce::TextButton repeatButton { "Repeat" };
    juce::TextButton gaplessButton { "Gapless" };
    juce::Slider positionSlider;
    juce::Slider volumeSlider;

    bool isSeeking = false;
    AudioEngine::State currentState;
    std::vector<int> visibleTrackIndices;

    juce::Rectangle<int> panelBounds;
    juce::Rectangle<int> nowPlayingBounds;
    juce::Rectangle<int> playlistBounds;
    juce::Rectangle<int> transportBounds;
    juce::Rectangle<int> artworkBounds;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PlayerPanel)
};
