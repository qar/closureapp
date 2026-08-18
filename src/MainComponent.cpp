#include "MainComponent.h"

MainComponent::MainComponent()
    : playerPanel(audioEngine)
{
    setSize(820, 620);
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
    // Soft sky gradient behind glass — evokes late-2000s player skins
    juce::ColourGradient bg(juce::Colour(0xffa8c0ff), 0.0f, 0.0f,
                            juce::Colour(0xfff0e6ff), 0.0f, (float) getHeight(), false);
    bg.addColour(0.45, juce::Colour(0xffc9d8ff));
    g.setGradientFill(bg);
    g.fillAll();

    // Subtle vignette
    juce::ColourGradient vig(juce::Colours::transparentBlack, (float) getWidth() * 0.5f, (float) getHeight() * 0.4f,
                             juce::Colours::black.withAlpha(0.12f), 0.0f, 0.0f, true);
    g.setGradientFill(vig);
    g.fillAll();
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
        const auto ext = f.getFileExtension().toLowerCase();
        if (ext == ".mp3" || ext == ".flac" || ext == ".wav" || ext == ".aiff"
            || ext == ".aif" || ext == ".m4a" || ext == ".alac" || ext == ".ogg")
            return true;
    }
    return false;
}

void MainComponent::filesDropped(const juce::StringArray& files, int, int)
{
    juce::Array<juce::File> audioFiles;
    for (const auto& path : files)
    {
        const juce::File f(path);
        const auto ext = f.getFileExtension().toLowerCase();
        if (ext == ".mp3" || ext == ".flac" || ext == ".wav" || ext == ".aiff"
            || ext == ".aif" || ext == ".m4a" || ext == ".alac" || ext == ".ogg")
            audioFiles.add(f);
    }

    audioEngine.addFiles(audioFiles);
}
