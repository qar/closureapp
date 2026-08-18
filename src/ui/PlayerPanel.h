#pragma once

#include <JuceHeader.h>
#include "audio/AudioEngine.h"
#include "ui/GlassLookAndFeel.h"

class PlayerPanel final : public juce::Component
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

    AudioEngine& audioEngine;
    GlassLookAndFeel glassLf;

    juce::Label titleLabel;
    juce::Label timeLabel;
    juce::TextButton openButton { "Open" };
    juce::TextButton playButton { "Play" };
    juce::TextButton stopButton { "Stop" };
    juce::Slider positionSlider;
    juce::Slider volumeSlider;

    bool isSeeking = false;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PlayerPanel)
};
