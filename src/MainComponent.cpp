#include "MainComponent.h"

MainComponent::MainComponent()
    : playerPanel(audioEngine)
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

    playerPanel.applyState(audioEngine.getState());
}

MainComponent::~MainComponent()
{
    audioEngine.setStateCallback(nullptr);
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

        const auto ext = f.getFileExtension().toLowerCase();
        if (ext == ".mp3" || ext == ".flac" || ext == ".wav" || ext == ".aiff"
            || ext == ".aif" || ext == ".m4a" || ext == ".alac" || ext == ".ogg")
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
