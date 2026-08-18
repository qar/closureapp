#include "PlayerPanel.h"

namespace
{
juce::String formatTime(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0.0)
        seconds = 0.0;

    const auto total = (int) std::floor(seconds);
    const auto m = total / 60;
    const auto s = total % 60;
    return juce::String::formatted("%d:%02d", m, s);
}
} // namespace

PlayerPanel::PlayerPanel(AudioEngine& engine)
    : audioEngine(engine)
{
    setLookAndFeel(&glassLf);

    titleLabel.setText("Drop a track, or Open", juce::dontSendNotification);
    titleLabel.setJustificationType(juce::Justification::centred);
    titleLabel.setFont(juce::Font(juce::FontOptions(18.0f)));
    titleLabel.setColour(juce::Label::textColourId, GlassLookAndFeel::inkPrimary());
    addAndMakeVisible(titleLabel);

    timeLabel.setText("0:00 / 0:00", juce::dontSendNotification);
    timeLabel.setJustificationType(juce::Justification::centred);
    timeLabel.setColour(juce::Label::textColourId, GlassLookAndFeel::inkMuted());
    addAndMakeVisible(timeLabel);

    openButton.onClick = [this] { openFileChooser(); };
    playButton.onClick = [this] { audioEngine.togglePlayPause(); };
    stopButton.onClick = [this] { audioEngine.stop(); };
    addAndMakeVisible(openButton);
    addAndMakeVisible(playButton);
    addAndMakeVisible(stopButton);

    positionSlider.setSliderStyle(juce::Slider::LinearHorizontal);
    positionSlider.setTextBoxStyle(juce::Slider::NoTextBox, false, 0, 0);
    positionSlider.setRange(0.0, 1.0, 0.0);
    positionSlider.onDragStart = [this] { isSeeking = true; };
    positionSlider.onDragEnd = [this]
    {
        seekFromSlider();
        isSeeking = false;
    };
    addAndMakeVisible(positionSlider);

    volumeSlider.setSliderStyle(juce::Slider::LinearHorizontal);
    volumeSlider.setTextBoxStyle(juce::Slider::NoTextBox, false, 0, 0);
    volumeSlider.setRange(0.0, 1.0, 0.01);
    volumeSlider.setValue(0.85);
    volumeSlider.onValueChange = [this]
    {
        audioEngine.setGain((float) volumeSlider.getValue());
    };
    audioEngine.setGain(0.85f);
    addAndMakeVisible(volumeSlider);
}

PlayerPanel::~PlayerPanel()
{
    setLookAndFeel(nullptr);
}

void PlayerPanel::paint(juce::Graphics& g)
{
    auto bounds = getLocalBounds().toFloat().reduced(18.0f);

    g.setColour(juce::Colour(0x4cffffff));
    g.fillRoundedRectangle(bounds, 22.0f);

    g.setColour(juce::Colour(0x66ffffff));
    g.drawRoundedRectangle(bounds, 22.0f, 1.2f);

    juce::ColourGradient topGloss(juce::Colours::white.withAlpha(0.28f),
                                  bounds.getX(), bounds.getY(),
                                  juce::Colours::transparentWhite,
                                  bounds.getX(), bounds.getY() + 80.0f, false);
    g.setGradientFill(topGloss);
    g.fillRoundedRectangle(bounds.removeFromTop(90.0f), 22.0f);
}

void PlayerPanel::resized()
{
    auto area = getLocalBounds().reduced(40);
    titleLabel.setBounds(area.removeFromTop(36));
    area.removeFromTop(6);
    timeLabel.setBounds(area.removeFromTop(22));
    area.removeFromTop(18);

    positionSlider.setBounds(area.removeFromTop(28));
    area.removeFromTop(16);

    auto controls = area.removeFromTop(40);
    const int gap = 12;
    const int btnW = 88;
    auto row = controls.withSizeKeepingCentre(btnW * 3 + gap * 2, 36);
    openButton.setBounds(row.removeFromLeft(btnW));
    row.removeFromLeft(gap);
    playButton.setBounds(row.removeFromLeft(btnW));
    row.removeFromLeft(gap);
    stopButton.setBounds(row.removeFromLeft(btnW));

    area.removeFromTop(20);
    auto volRow = area.removeFromTop(28);
    volumeSlider.setBounds(volRow.withSizeKeepingCentre(juce::jmin(220, volRow.getWidth()), 24));
}

void PlayerPanel::applyState(const AudioEngine::State& state)
{
    if (state.hasFile)
        titleLabel.setText(state.fileName, juce::dontSendNotification);
    else
        titleLabel.setText("Drop a track, or Open", juce::dontSendNotification);

    playButton.setButtonText(state.isPlaying ? "Pause" : "Play");

    timeLabel.setText(formatTime(state.positionSeconds) + " / " + formatTime(state.lengthSeconds),
                      juce::dontSendNotification);

    if (!isSeeking)
    {
        positionSlider.setRange(0.0, juce::jmax(0.001, state.lengthSeconds), 0.0);
        positionSlider.setValue(state.positionSeconds, juce::dontSendNotification);
    }
}

void PlayerPanel::openFileChooser()
{
    auto chooser = std::make_shared<juce::FileChooser>(
        "Open audio file",
        juce::File::getSpecialLocation(juce::File::userMusicDirectory),
        "*.mp3;*.flac;*.wav;*.aiff;*.aif;*.m4a;*.alac;*.ogg");

    const auto flags = juce::FileBrowserComponent::openMode
                     | juce::FileBrowserComponent::canSelectFiles;

    chooser->launchAsync(flags, [this, chooser](const juce::FileChooser& fc)
    {
        auto file = fc.getResult();
        if (file == juce::File{})
            return;

        if (audioEngine.openFile(file))
            audioEngine.play();
    });
}

void PlayerPanel::seekFromSlider()
{
    audioEngine.setPosition(positionSlider.getValue());
}
