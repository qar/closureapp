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

    int getNumRows() override;
    void paintListBoxItem(int rowNumber,
                          juce::Graphics& g,
                          int width,
                          int height,
                          bool rowIsSelected) override;
    void listBoxItemClicked(int rowNumber, const juce::MouseEvent&) override;

    AudioEngine& audioEngine;
    GlassLookAndFeel glassLf;

    juce::Label titleLabel;
    juce::Label timeLabel;
    juce::Label playlistLabel;
    juce::Label playlistInfoLabel;
    juce::ListBox playlistList;
    juce::TextButton addButton { "Add Files" };
    juce::TextButton playButton { "Play" };
    juce::TextButton stopButton { "Stop" };
    juce::TextButton loopButton { "Loop On" };
    juce::Slider positionSlider;
    juce::Slider volumeSlider;

    bool isSeeking = false;
    AudioEngine::State currentState;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PlayerPanel)
};
