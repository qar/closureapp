#pragma once

#include <JuceHeader.h>
#include "audio/AudioEngine.h"
#include "ui/GlassLookAndFeel.h"

#include <array>

class PlayerPanel final : public juce::Component,
                          private juce::ListBoxModel,
                          private juce::Timer
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
    void updateVisualModeLabel();
    void updateSpectrum();
    void timerCallback() override;

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
    void drawSpectrum(juce::Graphics& g,
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
    juce::TextButton visualModeButton { "Spectrum" };
    juce::Slider positionSlider;
    juce::Slider volumeSlider;

    // 4096 samples reaches the sub-20 Hz region while retaining the full Nyquist range.
    static constexpr int spectrumOrder = 12;
    static constexpr int spectrumSize = 1 << spectrumOrder;
    static constexpr int spectrumBarCount = 48;
    static constexpr int spectrumReadSize = 2048;

    bool isSeeking = false;
    bool showSpectrum = false;
    AudioEngine::State currentState;
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
    juce::Rectangle<int> artworkBounds;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PlayerPanel)
};
