#pragma once

#include <JuceHeader.h>
#include "audio/AudioEngine.h"
#include "library/MusicLibrary.h"
#include "ui/PlayerPanel.h"

class MainComponent final : public juce::Component,
                            public juce::FileDragAndDropTarget
{
public:
    MainComponent();
    ~MainComponent() override;

    void paint(juce::Graphics& g) override;
    void resized() override;

    bool isInterestedInFileDrag(const juce::StringArray& files) override;
    void filesDropped(const juce::StringArray& files, int x, int y) override;

private:
    MusicLibrary musicLibrary;
    AudioEngine audioEngine;
    PlayerPanel playerPanel;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(MainComponent)
};
