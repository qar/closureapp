#include "MainComponent.h"
#include "audio/AudioFileFormats.h"

MainComponent::MainComponent()
    : playerPanel(audioEngine, musicLibrary)
{
    setOpaque(true);
    setSize(1040, 700);
    addAndMakeVisible(playerPanel);

    const juce::Component::SafePointer<PlayerPanel> safePanel { &playerPanel };
    audioEngine.setStateCallback([safePanel](const AudioEngine::State& state)
    {
        juce::MessageManager::callAsync([safePanel, state]
        {
            if (safePanel != nullptr)
                safePanel->applyState(state);
        });
    });

    musicLibrary.setStateCallback([safePanel](const MusicLibrary::State& state)
    {
        juce::MessageManager::callAsync([safePanel, state]
        {
            if (safePanel != nullptr)
                safePanel->applyLibraryState(state);
        });
    });

    playerPanel.applyState(audioEngine.getState());
    playerPanel.applyLibraryState(musicLibrary.getState());
}

MainComponent::~MainComponent()
{
    audioEngine.setStateCallback(nullptr);
    musicLibrary.setStateCallback(nullptr);
}

void MainComponent::paint(juce::Graphics& g)
{
    g.fillAll(juce::Colour(0xfff5f7fb));
}

void MainComponent::resized()
{
    playerPanel.setBounds(getLocalBounds());
}

bool MainComponent::isInterestedInFileDrag(const juce::StringArray& files)
{
    for (const auto& path : files)
    {
        const juce::File f(path);
        if (f.isDirectory())
            return true;

        if (AudioFileFormats::isSupported(f))
            return true;
    }
    return false;
}

void MainComponent::filesDropped(const juce::StringArray& files, int, int)
{
    juce::Array<juce::File> inputs;
    for (const auto& path : files)
    {
        const juce::File f(path);
        if (f.isDirectory() || f.existsAsFile())
            inputs.add(f);
    }

    audioEngine.addFiles(inputs);
}
