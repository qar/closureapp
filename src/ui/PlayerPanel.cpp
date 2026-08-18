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

    playlistLabel.setText("DEFAULT PLAYLIST", juce::dontSendNotification);
    playlistLabel.setFont(juce::Font(juce::FontOptions(12.0f)).boldened());
    playlistLabel.setColour(juce::Label::textColourId, GlassLookAndFeel::inkMuted());
    addAndMakeVisible(playlistLabel);

    playlistInfoLabel.setJustificationType(juce::Justification::centredRight);
    playlistInfoLabel.setColour(juce::Label::textColourId, GlassLookAndFeel::inkMuted());
    addAndMakeVisible(playlistInfoLabel);

    playlistList.setModel(this);
    playlistList.setRowHeight(34);
    playlistList.setColour(juce::ListBox::backgroundColourId, juce::Colours::transparentBlack);
    playlistList.setColour(juce::ListBox::outlineColourId, GlassLookAndFeel::glassStroke());
    playlistList.setOutlineThickness(1);
    addAndMakeVisible(playlistList);

    titleLabel.setText("Add a track to begin", juce::dontSendNotification);
    titleLabel.setJustificationType(juce::Justification::centred);
    titleLabel.setFont(juce::Font(juce::FontOptions(18.0f)));
    titleLabel.setColour(juce::Label::textColourId, GlassLookAndFeel::inkPrimary());
    addAndMakeVisible(titleLabel);

    timeLabel.setText("0:00 / 0:00", juce::dontSendNotification);
    timeLabel.setJustificationType(juce::Justification::centred);
    timeLabel.setColour(juce::Label::textColourId, GlassLookAndFeel::inkMuted());
    addAndMakeVisible(timeLabel);

    addButton.onClick = [this] { openFileChooser(); };
    playButton.onClick = [this] { audioEngine.togglePlayPause(); };
    stopButton.onClick = [this] { audioEngine.stop(); };
    loopButton.onClick = [this] { audioEngine.setLoopPlaylist(!currentState.loopPlaylist); };
    addAndMakeVisible(addButton);
    addAndMakeVisible(playButton);
    addAndMakeVisible(stopButton);
    addAndMakeVisible(loopButton);

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
    playlistList.setModel(nullptr);
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
    auto area = getLocalBounds().reduced(36, 28);

    auto playlistHeader = area.removeFromTop(28);
    loopButton.setBounds(playlistHeader.removeFromRight(92).withSizeKeepingCentre(92, 28));
    playlistInfoLabel.setBounds(playlistHeader.removeFromRight(82));
    playlistLabel.setBounds(playlistHeader);

    area.removeFromTop(8);
    const auto listHeight = juce::jlimit(110, 220, area.getHeight() / 3);
    playlistList.setBounds(area.removeFromTop(listHeight));
    area.removeFromTop(14);

    titleLabel.setBounds(area.removeFromTop(30));
    area.removeFromTop(2);
    timeLabel.setBounds(area.removeFromTop(22));
    area.removeFromTop(10);

    positionSlider.setBounds(area.removeFromTop(26));
    area.removeFromTop(10);

    auto controls = area.removeFromTop(36);
    const int gap = 8;
    const int buttonWidth = juce::jmax(1, (controls.getWidth() - gap * 3) / 4);
    auto row = controls.withSizeKeepingCentre(buttonWidth * 4 + gap * 3, 34);
    addButton.setBounds(row.removeFromLeft(buttonWidth));
    row.removeFromLeft(gap);
    playButton.setBounds(row.removeFromLeft(buttonWidth));
    row.removeFromLeft(gap);
    stopButton.setBounds(row.removeFromLeft(buttonWidth));
    row.removeFromLeft(gap);
    loopButton.setBounds(row.removeFromLeft(buttonWidth));

    area.removeFromTop(12);
    auto volRow = area.removeFromTop(24);
    volumeSlider.setBounds(volRow.withSizeKeepingCentre(juce::jmin(220, volRow.getWidth()), 24));
}

void PlayerPanel::applyState(const AudioEngine::State& state)
{
    currentState = state;

    if (state.hasFile)
        titleLabel.setText(state.fileName, juce::dontSendNotification);
    else
        titleLabel.setText("Add a track to begin", juce::dontSendNotification);

    playButton.setButtonText(state.isPlaying ? "Pause" : "Play");
    loopButton.setButtonText(state.loopPlaylist ? "Loop On" : "Loop Off");
    playlistInfoLabel.setText(juce::String(state.playlistNames.size()) + " tracks",
                              juce::dontSendNotification);

    playlistList.updateContent();
    playlistList.deselectAllRows();
    if (juce::isPositiveAndBelow(state.currentTrackIndex, state.playlistNames.size()))
        playlistList.selectRow(state.currentTrackIndex, true);

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
        "Add audio files",
        juce::File::getSpecialLocation(juce::File::userMusicDirectory),
        "*.mp3;*.flac;*.wav;*.aiff;*.aif;*.m4a;*.alac;*.ogg");

    const auto flags = juce::FileBrowserComponent::openMode
                     | juce::FileBrowserComponent::canSelectFiles
                     | juce::FileBrowserComponent::canSelectMultipleItems;

    chooser->launchAsync(flags, [this, chooser](const juce::FileChooser& fc)
    {
        const auto files = fc.getResults();
        if (files.isEmpty())
            return;

        audioEngine.addFiles(files);
    });
}

void PlayerPanel::seekFromSlider()
{
    audioEngine.setPosition(positionSlider.getValue());
}

int PlayerPanel::getNumRows()
{
    return currentState.playlistNames.size();
}

void PlayerPanel::paintListBoxItem(int rowNumber,
                                   juce::Graphics& g,
                                   int width,
                                   int height,
                                   bool rowIsSelected)
{
    if (!juce::isPositiveAndBelow(rowNumber, currentState.playlistNames.size()))
        return;

    if (rowIsSelected)
    {
        g.setColour(GlassLookAndFeel::accent().withAlpha(0.18f));
        g.fillRoundedRectangle(4.0f, 3.0f, static_cast<float>(width - 8), static_cast<float>(height - 6), 8.0f);
    }

    g.setColour(rowIsSelected ? GlassLookAndFeel::inkPrimary() : GlassLookAndFeel::inkMuted());
    g.setFont(juce::Font(juce::FontOptions(13.0f)));
    g.drawText(juce::String(rowNumber + 1).paddedLeft('0', 2)
                   + "  " + currentState.playlistNames[rowNumber],
               14,
               0,
               width - 28,
               height,
               juce::Justification::centredLeft,
               true);
}

void PlayerPanel::listBoxItemClicked(int rowNumber, const juce::MouseEvent&)
{
    audioEngine.playTrack(rowNumber);
}
