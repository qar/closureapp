#include "PlayerPanel.h"

#include <cmath>

namespace
{
constexpr int outerMargin = 24;
constexpr int headerHeight = 54;
constexpr int sectionGap = 20;
constexpr int transportHeight = 148;

juce::Colour backgroundColour()
{
    return juce::Colour(0xfff5f7fb);
}

juce::Colour cardColour()
{
    return juce::Colour(0xffffffff);
}

juce::Colour borderColour()
{
    return juce::Colour(0xffe1e6ef);
}

juce::String formatTime(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0.0)
        seconds = 0.0;

    const auto total = static_cast<int>(std::floor(seconds));
    return juce::String::formatted("%d:%02d", total / 60, total % 60);
}

juce::Font makeFont(float size, bool bold = false)
{
    const auto font = juce::Font(juce::FontOptions(size));
    return bold ? font.boldened() : font;
}

void configureLabel(juce::Label& label,
                    const juce::String& text,
                    float size,
                    juce::Colour colour,
                    bool bold = false,
                    juce::Justification justification = juce::Justification::centredLeft)
{
    label.setText(text, juce::dontSendNotification);
    label.setFont(makeFont(size, bold));
    label.setColour(juce::Label::textColourId, colour);
    label.setJustificationType(justification);
    label.setInterceptsMouseClicks(false, false);
}

juce::Colour artworkColour(const juce::String& key)
{
    const auto hash = static_cast<uint32_t>(key.hashCode());
    const auto hue = static_cast<float>(hash % 1000u) / 1000.0f;
    return juce::Colour::fromHSV(hue, 0.48f, 0.86f, 1.0f);
}
}

PlayerPanel::PlayerPanel(AudioEngine& engine)
    : audioEngine(engine)
{
    setOpaque(true);
    setLookAndFeel(&lookAndFeel);

    configureLabel(appTitleLabel, "CLOSURE", 22.0f, GlassLookAndFeel::inkPrimary(), true);
    configureLabel(appSubtitleLabel, "Local music", 12.0f, GlassLookAndFeel::inkMuted());
    addAndMakeVisible(appTitleLabel);
    addAndMakeVisible(appSubtitleLabel);

    configureLabel(playlistLabel, "Playlist", 18.0f, GlassLookAndFeel::inkPrimary(), true);
    configureLabel(playlistInfoLabel, "0 tracks", 12.0f, GlassLookAndFeel::inkMuted(), false,
                   juce::Justification::centredRight);
    addAndMakeVisible(playlistLabel);
    addAndMakeVisible(playlistInfoLabel);

    configureLabel(currentTitleLabel, "Nothing playing", 20.0f,
                   GlassLookAndFeel::inkPrimary(), true);
    configureLabel(currentArtistLabel, "Add audio files to begin", 13.0f,
                   GlassLookAndFeel::inkMuted());
    configureLabel(currentAlbumLabel, "", 12.0f, GlassLookAndFeel::inkMuted());
    addAndMakeVisible(currentTitleLabel);
    addAndMakeVisible(currentArtistLabel);
    addAndMakeVisible(currentAlbumLabel);

    configureLabel(emptyStateLabel,
                   "Your playlist is empty\nAdd audio files or folders to start listening",
                   14.0f,
                   GlassLookAndFeel::inkMuted(),
                   false,
                   juce::Justification::centred);
    addAndMakeVisible(emptyStateLabel);

    configureLabel(timeLabel, "0:00 / 0:00", 12.0f, GlassLookAndFeel::inkMuted(), false,
                   juce::Justification::centredRight);
    configureLabel(volumeLabel, "Volume", 12.0f, GlassLookAndFeel::inkMuted(), true);
    addAndMakeVisible(timeLabel);
    addAndMakeVisible(volumeLabel);

    addButton.setComponentID("primary");
    addButton.setTooltip("Add audio files or folders");
    addButton.setName("Add audio files or folders");
    addButton.onClick = [this] { openFileChooser(); };

    clearButton.setComponentID("quiet");
    clearButton.setTooltip("Clear the playlist");
    clearButton.setName("Clear playlist");
    clearButton.onClick = [this] { audioEngine.clearPlaylist(); };

    previousButton.setComponentID("control");
    previousButton.setTooltip("Previous track");
    previousButton.setName("Previous track");
    previousButton.onClick = [this] { audioEngine.playPrevious(); };

    playButton.setComponentID("primary");
    playButton.setTooltip("Play");
    playButton.setName("Play");
    playButton.onClick = [this] { audioEngine.togglePlayPause(); };

    stopButton.setComponentID("control");
    stopButton.setTooltip("Stop");
    stopButton.setName("Stop");
    stopButton.onClick = [this] { audioEngine.stop(); };

    nextButton.setComponentID("control");
    nextButton.setTooltip("Next track");
    nextButton.setName("Next track");
    nextButton.onClick = [this] { audioEngine.playNext(); };

    repeatButton.setComponentID("option");
    repeatButton.setTooltip("Cycle repeat mode");
    repeatButton.setName("Repeat mode");
    repeatButton.onClick = [this]
    {
        auto mode = AudioEngine::RepeatMode::off;
        switch (currentState.repeatMode)
        {
            case AudioEngine::RepeatMode::off:
                mode = AudioEngine::RepeatMode::single;
                break;
            case AudioEngine::RepeatMode::single:
                mode = AudioEngine::RepeatMode::playlist;
                break;
            case AudioEngine::RepeatMode::playlist:
                mode = AudioEngine::RepeatMode::off;
                break;
        }

        audioEngine.setRepeatMode(mode);
    };

    gaplessButton.setComponentID("option");
    gaplessButton.setTooltip("Toggle gapless playback");
    gaplessButton.setName("Gapless playback");
    gaplessButton.onClick = [this]
    {
        audioEngine.setGaplessPlayback(!currentState.gaplessPlayback);
    };

    addAndMakeVisible(addButton);
    addAndMakeVisible(clearButton);
    addAndMakeVisible(previousButton);
    addAndMakeVisible(playButton);
    addAndMakeVisible(stopButton);
    addAndMakeVisible(nextButton);
    addAndMakeVisible(repeatButton);
    addAndMakeVisible(gaplessButton);

    playlistList.setModel(this);
    playlistList.setRowHeight(64);
    playlistList.setColour(juce::ListBox::backgroundColourId, juce::Colours::transparentBlack);
    playlistList.setColour(juce::ListBox::outlineColourId, juce::Colours::transparentBlack);
    playlistList.setOutlineThickness(0);
    playlistList.setMultipleSelectionEnabled(false);
    addAndMakeVisible(playlistList);

    emptyStateLabel.setVisible(true);

    positionSlider.setSliderStyle(juce::Slider::LinearHorizontal);
    positionSlider.setTextBoxStyle(juce::Slider::NoTextBox, false, 0, 0);
    positionSlider.setRange(0.0, 1.0, 0.01);
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
    volumeSlider.setValue(0.85, juce::dontSendNotification);
    volumeSlider.onValueChange = [this]
    {
        audioEngine.setGain(static_cast<float>(volumeSlider.getValue()));
    };
    audioEngine.setGain(0.85f);
    addAndMakeVisible(volumeSlider);

    updateControlLabels();
}

PlayerPanel::~PlayerPanel()
{
    playlistList.setModel(nullptr);
    setLookAndFeel(nullptr);
}

void PlayerPanel::paint(juce::Graphics& g)
{
    g.fillAll(backgroundColour());
    drawCard(g, nowPlayingBounds.toFloat());
    drawCard(g, playlistBounds.toFloat());
    drawTransportSurface(g, transportBounds.toFloat());

    drawArtwork(g,
                artworkBounds.toFloat(),
                metadataAt(currentState.currentTrackIndex),
                currentState.filePath.isNotEmpty() ? currentState.filePath : "empty-library");
}

void PlayerPanel::resized()
{
    panelBounds = getLocalBounds().reduced(outerMargin, 20);
#if JUCE_MAC
    panelBounds.removeFromTop(38);
#endif

    auto header = panelBounds.removeFromTop(headerHeight);
    auto headerActions = header.removeFromRight(214);
    clearButton.setBounds(headerActions.removeFromRight(76).withSizeKeepingCentre(76, 34));
    headerActions.removeFromRight(10);
    addButton.setBounds(headerActions.removeFromRight(128).withSizeKeepingCentre(128, 34));

    appTitleLabel.setBounds(header.removeFromTop(28));
    appSubtitleLabel.setBounds(header);

    panelBounds.removeFromTop(sectionGap);
    transportBounds = panelBounds.removeFromBottom(transportHeight);
    panelBounds.removeFromBottom(sectionGap);

    auto mainArea = panelBounds;
    const auto leftWidth = juce::jlimit(270, 340, mainArea.getWidth() * 36 / 100);
    nowPlayingBounds = mainArea.removeFromLeft(leftWidth);
    mainArea.removeFromLeft(sectionGap);
    playlistBounds = mainArea;

    auto nowArea = nowPlayingBounds.reduced(24, 22);
    const auto infoHeight = 84;
    const auto coverSize = juce::jmax(0, juce::jmin(nowArea.getWidth(), nowArea.getHeight() - infoHeight));
    artworkBounds = nowArea.removeFromTop(coverSize).withSizeKeepingCentre(coverSize, coverSize);
    nowArea.removeFromTop(16);
    currentTitleLabel.setBounds(nowArea.removeFromTop(28));
    currentArtistLabel.setBounds(nowArea.removeFromTop(24));
    currentAlbumLabel.setBounds(nowArea.removeFromTop(22));

    auto playlistArea = playlistBounds.reduced(20, 18);
    auto playlistHeader = playlistArea.removeFromTop(32);
    playlistInfoLabel.setBounds(playlistHeader.removeFromRight(92));
    playlistLabel.setBounds(playlistHeader);
    playlistArea.removeFromTop(10);
    playlistList.setBounds(playlistArea);
    emptyStateLabel.setBounds(playlistArea.reduced(16, 12));

    auto transport = transportBounds.reduced(18, 14);
    auto progressRow = transport.removeFromTop(24);
    timeLabel.setBounds(progressRow.removeFromRight(92));
    progressRow.removeFromRight(10);
    positionSlider.setBounds(progressRow);

    transport.removeFromTop(12);
    auto actionRow = transport;

    auto options = actionRow.removeFromLeft(204);
    repeatButton.setBounds(options.removeFromLeft(98).withSizeKeepingCentre(98, 34));
    options.removeFromLeft(8);
    gaplessButton.setBounds(options.removeFromLeft(98).withSizeKeepingCentre(98, 34));

    auto volume = actionRow.removeFromRight(166);
    volumeLabel.setBounds(volume.removeFromLeft(52));
    volume.removeFromLeft(8);
    volumeSlider.setBounds(volume.withSizeKeepingCentre(volume.getWidth(), 24));

    auto controls = actionRow.withSizeKeepingCentre(270, 38);
    previousButton.setBounds(controls.removeFromLeft(58));
    controls.removeFromLeft(8);
    stopButton.setBounds(controls.removeFromLeft(58));
    controls.removeFromLeft(8);
    playButton.setBounds(controls.removeFromLeft(80));
    controls.removeFromLeft(8);
    nextButton.setBounds(controls.removeFromLeft(58));
}

void PlayerPanel::applyState(const AudioEngine::State& state)
{
    currentState = state;
    rebuildPlaylistRows();

    if (juce::isPositiveAndBelow(currentState.currentTrackIndex,
                                 currentState.playlistPaths.size()))
    {
        currentTitleLabel.setText(titleAt(currentState.currentTrackIndex), juce::dontSendNotification);
        currentArtistLabel.setText(artistAt(currentState.currentTrackIndex), juce::dontSendNotification);
        currentAlbumLabel.setText(albumAt(currentState.currentTrackIndex), juce::dontSendNotification);
    }
    else
    {
        currentTitleLabel.setText("Nothing playing", juce::dontSendNotification);
        currentArtistLabel.setText("Add audio files or folders to begin", juce::dontSendNotification);
        currentAlbumLabel.setText("", juce::dontSendNotification);
    }

    playlistInfoLabel.setText(juce::String(currentState.playlistPaths.size())
                                  + (currentState.playlistPaths.size() == 1 ? " track" : " tracks"),
                              juce::dontSendNotification);

    emptyStateLabel.setVisible(currentState.playlistPaths.isEmpty());
    updateControlLabels();

    playlistList.updateContent();
    playlistList.deselectAllRows();
    if (juce::isPositiveAndBelow(currentState.currentTrackIndex,
                                 static_cast<int>(visibleTrackIndices.size())))
    {
        playlistList.selectRow(currentState.currentTrackIndex, true);
    }

    if (!isSeeking)
    {
        positionSlider.setRange(0.0, juce::jmax(0.01, currentState.lengthSeconds), 0.01);
        positionSlider.setValue(currentState.positionSeconds, juce::dontSendNotification);
    }

    timeLabel.setText(formatTime(currentState.positionSeconds) + " / "
                          + formatTime(currentState.lengthSeconds),
                      juce::dontSendNotification);
    repaint();
}

void PlayerPanel::openFileChooser()
{
    auto chooser = std::make_shared<juce::FileChooser>(
        "Add audio files or folders",
        juce::File::getSpecialLocation(juce::File::userMusicDirectory),
        "*.mp3;*.flac;*.wav;*.aiff;*.aif;*.m4a;*.alac;*.ogg");

    const auto flags = juce::FileBrowserComponent::openMode
                     | juce::FileBrowserComponent::canSelectFiles
                     | juce::FileBrowserComponent::canSelectDirectories
                     | juce::FileBrowserComponent::canSelectMultipleItems;

    chooser->launchAsync(flags, [this, chooser](const juce::FileChooser& fileChooser)
    {
        const auto selected = fileChooser.getResults();
        if (!selected.isEmpty())
            audioEngine.addFiles(selected);
    });
}

void PlayerPanel::seekFromSlider()
{
    audioEngine.setPosition(positionSlider.getValue());
}

void PlayerPanel::rebuildPlaylistRows()
{
    visibleTrackIndices.clear();
    visibleTrackIndices.reserve(static_cast<size_t>(currentState.playlistPaths.size()));

    for (int index = 0; index < currentState.playlistPaths.size(); ++index)
        visibleTrackIndices.push_back(index);
}

void PlayerPanel::updateControlLabels()
{
    const auto hasTracks = !currentState.playlistPaths.isEmpty();
    playButton.setButtonText(currentState.isPlaying ? "Pause" : "Play");
    playButton.setTooltip(currentState.isPlaying ? "Pause" : "Play");
    playButton.setName(currentState.isPlaying ? "Pause" : "Play");
    repeatButton.setButtonText(repeatModeText());
    repeatButton.setToggleState(currentState.repeatMode != AudioEngine::RepeatMode::off,
                                juce::dontSendNotification);
    gaplessButton.setButtonText(currentState.gaplessPlayback ? "Gapless: On" : "Gapless: Off");
    gaplessButton.setToggleState(currentState.gaplessPlayback, juce::dontSendNotification);

    playButton.setEnabled(hasTracks);
    previousButton.setEnabled(hasTracks);
    stopButton.setEnabled(hasTracks);
    nextButton.setEnabled(hasTracks);
    repeatButton.setEnabled(hasTracks);
    clearButton.setEnabled(hasTracks);
}

TrackMetadataPtr PlayerPanel::metadataAt(int index) const
{
    if (!juce::isPositiveAndBelow(index, static_cast<int>(currentState.playlistMetadata.size())))
        return nullptr;

    return currentState.playlistMetadata[static_cast<size_t>(index)];
}

juce::String PlayerPanel::titleAt(int index) const
{
    if (const auto metadata = metadataAt(index); metadata != nullptr && metadata->title.isNotEmpty())
        return metadata->title;

    if (juce::isPositiveAndBelow(index, currentState.playlistPaths.size()))
        return juce::File(currentState.playlistPaths[index]).getFileNameWithoutExtension();

    return "Untitled";
}

juce::String PlayerPanel::artistAt(int index) const
{
    if (const auto metadata = metadataAt(index); metadata != nullptr && metadata->artist.isNotEmpty())
        return metadata->artist;

    return "Unknown Artist";
}

juce::String PlayerPanel::albumAt(int index) const
{
    if (const auto metadata = metadataAt(index); metadata != nullptr && metadata->album.isNotEmpty())
        return metadata->album;

    return "Local Files";
}

double PlayerPanel::durationAt(int index) const
{
    if (const auto metadata = metadataAt(index); metadata != nullptr && metadata->durationSeconds > 0.0)
        return metadata->durationSeconds;

    return index == currentState.currentTrackIndex ? currentState.lengthSeconds : 0.0;
}

juce::String PlayerPanel::repeatModeText() const
{
    switch (currentState.repeatMode)
    {
        case AudioEngine::RepeatMode::off:
            return "Repeat: Off";
        case AudioEngine::RepeatMode::single:
            return "Repeat: One";
        case AudioEngine::RepeatMode::playlist:
            return "Repeat: All";
    }

    return "Repeat: Off";
}

void PlayerPanel::drawArtwork(juce::Graphics& g,
                              juce::Rectangle<float> bounds,
                              const TrackMetadataPtr& metadata,
                              const juce::String& fallbackKey) const
{
    if (bounds.isEmpty())
        return;

    juce::Path clip;
    clip.addRoundedRectangle(bounds, 12.0f);
    g.saveState();
    g.reduceClipRegion(clip);

    const bool hasContent = metadata != nullptr && metadata->file != juce::File{};
    if (hasContent && metadata->hasArtwork())
    {
        g.drawImageWithin(*metadata->artwork,
                          static_cast<int>(bounds.getX()),
                          static_cast<int>(bounds.getY()),
                          static_cast<int>(bounds.getWidth()),
                          static_cast<int>(bounds.getHeight()),
                          juce::RectanglePlacement::centred | juce::RectanglePlacement::fillDestination,
                          false);
        g.restoreState();
        return;
    }

    const auto colour = hasContent ? artworkColour(metadata->file.getFullPathName())
                                   : juce::Colour(0xffdce3ee);
    juce::ColourGradient gradient(colour.brighter(0.18f), bounds.getX(), bounds.getY(),
                                  colour.darker(0.18f), bounds.getRight(), bounds.getBottom(), true);
    g.setGradientFill(gradient);
    g.fillRect(bounds);

    const auto centre = bounds.getCentre();
    const auto radius = juce::jmin(bounds.getWidth(), bounds.getHeight()) * 0.19f;
    g.setColour(juce::Colours::white.withAlpha(hasContent ? 0.72f : 0.58f));
    g.drawEllipse(centre.x - radius, centre.y - radius, radius * 2.0f, radius * 2.0f, 3.0f);
    g.fillEllipse(centre.x - 5.0f, centre.y - 5.0f, 10.0f, 10.0f);
    g.drawLine(centre.x + radius * 0.72f, centre.y - radius * 0.72f,
               centre.x + radius * 0.72f, centre.y - radius * 1.65f, 3.0f);

    if (!hasContent)
    {
        const auto marker = fallbackKey.hashCode() % 3;
        g.setColour(GlassLookAndFeel::inkPrimary().withAlpha(0.14f));
        g.fillEllipse(centre.x - 30.0f + marker * 12.0f, centre.y + radius + 22.0f,
                      7.0f, 7.0f);
    }

    g.restoreState();
}

void PlayerPanel::drawCard(juce::Graphics& g, juce::Rectangle<float> bounds) const
{
    if (bounds.isEmpty())
        return;

    g.setColour(cardColour());
    g.fillRoundedRectangle(bounds, 16.0f);
    g.setColour(borderColour());
    g.drawRoundedRectangle(bounds, 16.0f, 1.0f);
}

void PlayerPanel::drawTransportSurface(juce::Graphics& g, juce::Rectangle<float> bounds) const
{
    if (bounds.isEmpty())
        return;

    g.setColour(cardColour());
    g.fillRoundedRectangle(bounds, 16.0f);
    g.setColour(borderColour());
    g.drawRoundedRectangle(bounds, 16.0f, 1.0f);
}

int PlayerPanel::getNumRows()
{
    return static_cast<int>(visibleTrackIndices.size());
}

void PlayerPanel::paintListBoxItem(int rowNumber,
                                   juce::Graphics& g,
                                   int width,
                                   int height,
                                   bool rowIsSelected)
{
    if (!juce::isPositiveAndBelow(rowNumber, static_cast<int>(visibleTrackIndices.size())))
        return;

    const auto trackIndex = visibleTrackIndices[static_cast<size_t>(rowNumber)];
    auto row = juce::Rectangle<float>(0.0f, 0.0f,
                                      static_cast<float>(width),
                                      static_cast<float>(height)).reduced(4.0f, 3.0f);
    const bool isCurrent = trackIndex == currentState.currentTrackIndex;

    if (rowIsSelected || isCurrent)
    {
        g.setColour(GlassLookAndFeel::accent().withAlpha(rowIsSelected ? 0.13f : 0.07f));
        g.fillRoundedRectangle(row, 10.0f);
    }

    const auto cover = row.removeFromLeft(48.0f).withSizeKeepingCentre(44.0f, 44.0f);
    drawArtwork(g, cover, metadataAt(trackIndex), currentState.playlistPaths[trackIndex]);
    row.removeFromLeft(14.0f);

    auto duration = row.removeFromRight(62.0f);
    g.setColour(GlassLookAndFeel::inkMuted());
    g.setFont(makeFont(11.0f));
    const auto durationSeconds = durationAt(trackIndex);
    if (durationSeconds > 0.0)
        g.drawText(formatTime(durationSeconds), duration.toNearestInt(), juce::Justification::centredRight, false);

    auto text = row.reduced(0.0f, 7.0f);
    auto title = text.removeFromTop(23.0f);
    auto details = text;
    g.setColour(isCurrent ? GlassLookAndFeel::accent().darker(0.2f)
                          : GlassLookAndFeel::inkPrimary());
    g.setFont(makeFont(13.0f, isCurrent));
    g.drawFittedText(titleAt(trackIndex), title.toNearestInt(), juce::Justification::centredLeft, 1);

    g.setColour(GlassLookAndFeel::inkMuted());
    g.setFont(makeFont(11.0f));
    g.drawFittedText(artistAt(trackIndex) + "  |  " + albumAt(trackIndex),
                     details.toNearestInt(), juce::Justification::centredLeft, 1);
}

void PlayerPanel::listBoxItemClicked(int rowNumber, const juce::MouseEvent&)
{
    if (juce::isPositiveAndBelow(rowNumber, static_cast<int>(visibleTrackIndices.size())))
        audioEngine.playTrack(visibleTrackIndices[static_cast<size_t>(rowNumber)]);
}
