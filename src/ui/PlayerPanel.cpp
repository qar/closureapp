#include "PlayerPanel.h"
#include "audio/AudioFileFormats.h"
#include "ui/icons/TransportIcons.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace
{
constexpr int outerMargin = 24;
constexpr int headerHeight = 54;
constexpr int sectionGap = 20;
constexpr int transportHeight = 148;

juce::Colour backgroundColour()
{
    return juce::Colour(0xfff3f5ef);
}

juce::Colour cardColour()
{
    return juce::Colour(0xffffffff);
}

juce::Colour borderColour()
{
    return GlassLookAndFeel::glassStroke();
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

juce::String svgColour(juce::Colour colour)
{
    return juce::String::formatted("#%02x%02x%02x",
                                   static_cast<int>(colour.getRed()),
                                   static_cast<int>(colour.getGreen()),
                                   static_cast<int>(colour.getBlue()));
}

std::unique_ptr<juce::Drawable> drawableFromSvg(const char* svg, juce::Colour colour)
{
    const auto svgText = juce::String(svg).replace("currentColor", svgColour(colour));
    if (const auto xml = juce::XmlDocument::parse(svgText))
        return juce::Drawable::createFromSVG(*xml);

    return nullptr;
}

void setTransportIcon(juce::DrawableButton& button, const char* svg)
{
    button.setEdgeIndent(9);
    const auto normal = drawableFromSvg(svg, GlassLookAndFeel::accent());
    const auto over = drawableFromSvg(svg, GlassLookAndFeel::accent().brighter(0.15f));
    const auto down = drawableFromSvg(svg, GlassLookAndFeel::accent().darker(0.12f));
    button.setImages(normal.get(), over.get(), down.get());
}
}

PlayerPanel::PlayerPanel(AudioEngine& engine, MusicLibrary& library)
    : audioEngine(engine),
      musicLibrary(library),
      spectrumFft(spectrumOrder),
      spectrumWindow(spectrumSize, juce::dsp::WindowingFunction<float>::hann)
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

    addAlbumButton.setComponentID("control");
    addAlbumButton.setTooltip("Add an album folder");
    addAlbumButton.setName("Add an album folder");
    addAlbumButton.onClick = [this] { openAlbumChooser(); };

    clearButton.setComponentID("quiet");
    clearButton.setTooltip("Clear the playlist");
    clearButton.setName("Clear playlist");
    clearButton.onClick = [this] { audioEngine.clearPlaylist(); };

    albumsViewButton.setComponentID("option");
    albumsViewButton.setTooltip("Show albums");
    albumsViewButton.setName("Show albums");
    albumsViewButton.onClick = [this] { showAlbumView(); };

    queueViewButton.setComponentID("option");
    queueViewButton.setTooltip("Show queue");
    queueViewButton.setName("Show queue");
    queueViewButton.onClick = [this] { showQueueView(); };

    previousButton.setComponentID("transport-previous");
    previousButton.setTooltip("Previous track");
    previousButton.setName("Previous track");
    previousButton.onClick = [this] { audioEngine.playPrevious(); };

    playButton.setComponentID("transport-play");
    playButton.setTooltip("Play");
    playButton.setName("Play");
    playButton.onClick = [this] { audioEngine.togglePlayPause(); };

    stopButton.setComponentID("transport-stop");
    stopButton.setTooltip("Stop");
    stopButton.setName("Stop");
    stopButton.onClick = [this] { audioEngine.stop(); };

    nextButton.setComponentID("transport-next");
    nextButton.setTooltip("Next track");
    nextButton.setName("Next track");
    nextButton.onClick = [this] { audioEngine.playNext(); };

    setTransportIcon(previousButton, ClosureTransportIcons::previous);
    setTransportIcon(playButton, ClosureTransportIcons::play);
    setTransportIcon(stopButton, ClosureTransportIcons::stop);
    setTransportIcon(nextButton, ClosureTransportIcons::next);

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

    visualModeButton.setComponentID("option");
    visualModeButton.setClickingTogglesState(true);
    visualModeButton.setTooltip("Switch between artwork and spectrum");
    visualModeButton.setName("Show spectrum");
    visualModeButton.onClick = [this]
    {
        showSpectrum = visualModeButton.getToggleState();
        updateVisualModeLabel();
        repaint(artworkBounds);
    };

    addAndMakeVisible(addButton);
    addAndMakeVisible(addAlbumButton);
    addAndMakeVisible(clearButton);
    addAndMakeVisible(albumsViewButton);
    addAndMakeVisible(queueViewButton);
    addAndMakeVisible(previousButton);
    addAndMakeVisible(playButton);
    addAndMakeVisible(stopButton);
    addAndMakeVisible(nextButton);
    addAndMakeVisible(repeatButton);
    addAndMakeVisible(gaplessButton);
    addAndMakeVisible(visualModeButton);

    playlistList.setModel(this);
    playlistList.setRowHeight(64);
    playlistList.setColour(juce::ListBox::backgroundColourId, juce::Colours::transparentBlack);
    playlistList.setColour(juce::ListBox::outlineColourId, juce::Colours::transparentBlack);
    playlistList.setOutlineThickness(0);
    playlistList.setMultipleSelectionEnabled(false);
    addAndMakeVisible(playlistList);

    albumBrowser.setPlayAlbumCallback([this](const juce::String& albumId)
    {
        playAlbum(albumId);
    });
    albumBrowser.setAddToQueueCallback([this](const juce::String& albumId)
    {
        addAlbumToQueue(albumId);
    });
    albumBrowser.setChooseArtworkCallback([this](const juce::String& albumId)
    {
        chooseAlbumArtwork(albumId);
    });
    albumBrowser.setEditAlbumCallback([this](const juce::String& albumId)
    {
        editAlbum(albumId);
    });
    albumBrowser.setRemoveAlbumCallback([this](const juce::String& albumId)
    {
        removeAlbum(albumId);
    });
    addAndMakeVisible(albumBrowser);

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
    showQueueView();
    startTimerHz(30);
}

PlayerPanel::~PlayerPanel()
{
    stopTimer();
    playlistList.setModel(nullptr);
    setLookAndFeel(nullptr);
}

void PlayerPanel::paint(juce::Graphics& g)
{
    g.fillAll(backgroundColour());
    drawCard(g, nowPlayingBounds.toFloat());
    drawCard(g, playlistBounds.toFloat());

    if (showSpectrum)
    {
        drawSpectrum(g,
                     artworkBounds.toFloat(),
                     currentState.currentTrackMetadata,
                     currentState.filePath.isNotEmpty() ? currentState.filePath : "empty-library");
    }
    else
    {
        drawArtwork(g,
                    artworkBounds.toFloat(),
                    currentState.currentTrackMetadata,
                    currentState.filePath.isNotEmpty() ? currentState.filePath : "empty-library");
    }
}

void PlayerPanel::resized()
{
    panelBounds = getLocalBounds().reduced(outerMargin, 20);
#if JUCE_MAC
    panelBounds.removeFromTop(38);
#endif

    auto header = panelBounds.removeFromTop(headerHeight);
    auto headerActions = header.removeFromRight(370);
    clearButton.setBounds(headerActions.removeFromRight(76).withSizeKeepingCentre(76, 34));
    headerActions.removeFromRight(10);
    addAlbumButton.setBounds(headerActions.removeFromRight(128).withSizeKeepingCentre(128, 34));
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
    visualModeButton.setBounds(artworkBounds.reduced(12).removeFromTop(34).removeFromRight(94));
    nowArea.removeFromTop(16);
    currentTitleLabel.setBounds(nowArea.removeFromTop(28));
    currentArtistLabel.setBounds(nowArea.removeFromTop(24));
    currentAlbumLabel.setBounds(nowArea.removeFromTop(22));

    auto playlistArea = playlistBounds.reduced(20, 18);
    auto playlistHeader = playlistArea.removeFromTop(32);
    playlistInfoLabel.setBounds(playlistHeader.removeFromRight(92));
    auto viewButtons = playlistHeader.removeFromRight(150);
    queueViewButton.setBounds(viewButtons.removeFromRight(72).withSizeKeepingCentre(68, 28));
    viewButtons.removeFromRight(6);
    albumsViewButton.setBounds(viewButtons.removeFromRight(72).withSizeKeepingCentre(68, 28));
    playlistLabel.setBounds(playlistHeader);
    playlistArea.removeFromTop(10);
    playlistList.setBounds(playlistArea);
    albumBrowser.setBounds(playlistArea);
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

    if (currentState.filePath.isNotEmpty())
    {
        const auto metadata = currentState.currentTrackMetadata;
        currentTitleLabel.setText(metadata != nullptr && metadata->title.isNotEmpty()
                                      ? metadata->title
                                      : juce::File(currentState.filePath).getFileNameWithoutExtension(),
                                  juce::dontSendNotification);
        currentArtistLabel.setText(metadata != nullptr && metadata->artist.isNotEmpty()
                                       ? metadata->artist
                                       : "Unknown Artist",
                                   juce::dontSendNotification);
        currentAlbumLabel.setText(metadata != nullptr && metadata->album.isNotEmpty()
                                      ? metadata->album
                                      : currentState.activePlaylistName,
                                  juce::dontSendNotification);
    }
    else
    {
        currentTitleLabel.setText("Nothing playing", juce::dontSendNotification);
        currentArtistLabel.setText("Add audio files or folders to begin", juce::dontSendNotification);
        currentAlbumLabel.setText("", juce::dontSendNotification);
    }

    if (!showingAlbums)
    {
        playlistInfoLabel.setText(juce::String(currentState.playlistPaths.size())
                                      + (currentState.playlistPaths.size() == 1 ? " track" : " tracks"),
                                  juce::dontSendNotification);
    }

    emptyStateLabel.setVisible(!showingAlbums && currentState.playlistPaths.isEmpty());
    updateControlLabels();

    playlistList.updateContent();
    playlistList.deselectAllRows();
    if (currentState.queueIsActive
        && juce::isPositiveAndBelow(currentState.currentTrackIndex,
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

void PlayerPanel::applyLibraryState(const MusicLibrary::State& state)
{
    libraryState = state;
    albumBrowser.setState(state);
    if (showingAlbums)
    {
        playlistInfoLabel.setText(juce::String(libraryState.albums.size())
                                      + (libraryState.albums.size() == 1 ? " album" : " albums"),
                                  juce::dontSendNotification);
    }
}

void PlayerPanel::openFileChooser()
{
    auto chooser = std::make_shared<juce::FileChooser>(
        "Add audio files or folders",
        juce::File::getSpecialLocation(juce::File::userMusicDirectory),
        AudioFileFormats::wildcardPattern());

    const auto flags = juce::FileBrowserComponent::openMode
                     | juce::FileBrowserComponent::canSelectFiles
                     | juce::FileBrowserComponent::canSelectDirectories
                     | juce::FileBrowserComponent::canSelectMultipleItems;

    const juce::Component::SafePointer<PlayerPanel> safePanel { this };
    chooser->launchAsync(flags, [safePanel, chooser](const juce::FileChooser& fileChooser)
    {
        const auto selected = fileChooser.getResults();
        if (safePanel != nullptr && !selected.isEmpty())
            safePanel->audioEngine.addFiles(selected);
    });
}

void PlayerPanel::openAlbumChooser()
{
    auto chooser = std::make_shared<juce::FileChooser>(
        "Add album folder",
        juce::File::getSpecialLocation(juce::File::userMusicDirectory));

    const auto flags = juce::FileBrowserComponent::openMode
                     | juce::FileBrowserComponent::canSelectDirectories;
    const juce::Component::SafePointer<PlayerPanel> safePanel { this };
    chooser->launchAsync(flags, [safePanel, chooser](const juce::FileChooser& fileChooser)
    {
        const auto selected = fileChooser.getResult();
        if (safePanel == nullptr || selected == juce::File{})
            return;

        safePanel->addAlbumButton.setEnabled(false);
        safePanel->musicLibrary.addAlbumAsync(selected, [safePanel](MusicLibrary::AddResult result)
        {
            if (safePanel == nullptr)
                return;

            safePanel->addAlbumButton.setEnabled(true);

            if (!result.success)
            {
                juce::AlertWindow::showMessageBoxAsync(juce::MessageBoxIconType::WarningIcon,
                                                       "Add album",
                                                       result.error);
                return;
            }

            safePanel->showAlbumView();
            if (result.skippedTracks > 0)
            {
                juce::AlertWindow::showMessageBoxAsync(
                    juce::MessageBoxIconType::WarningIcon,
                    "Add album",
                    juce::String(result.addedTracks) + " tracks added, "
                        + juce::String(result.skippedTracks) + " tracks skipped.");
            }
        });
    });
}

void PlayerPanel::chooseAlbumArtwork(const juce::String& albumId)
{
    auto chooser = std::make_shared<juce::FileChooser>(
        "Choose album cover",
        juce::File::getSpecialLocation(juce::File::userPicturesDirectory),
        "*.png;*.jpg;*.jpeg");

    const auto flags = juce::FileBrowserComponent::openMode
                     | juce::FileBrowserComponent::canSelectFiles;
    const juce::Component::SafePointer<PlayerPanel> safePanel { this };
    chooser->launchAsync(flags, [safePanel, chooser, albumId](const juce::FileChooser& fileChooser)
    {
        const auto selected = fileChooser.getResult();
        if (safePanel == nullptr || selected == juce::File{})
            return;

        if (!safePanel->musicLibrary.setCustomArtwork(albumId, selected))
        {
            juce::AlertWindow::showMessageBoxAsync(juce::MessageBoxIconType::WarningIcon,
                                                   "Album cover",
                                                   "The selected image could not be loaded.");
        }
    });
}

void PlayerPanel::editAlbum(const juce::String& albumId)
{
    const auto album = musicLibrary.getAlbum(albumId);
    if (!album.has_value())
        return;

    auto* editor = new juce::AlertWindow("Edit album",
                                         "Update album details",
                                         juce::AlertWindow::NoIcon);
    editor->addTextEditor("title", album->title, "Title");
    editor->addTextEditor("artist", album->artist, "Artist");
    editor->addButton("Save", 1, juce::KeyPress(juce::KeyPress::returnKey));
    editor->addButton("Cancel", 0, juce::KeyPress(juce::KeyPress::escapeKey));

    const juce::Component::SafePointer<PlayerPanel> safePanel { this };
    editor->enterModalState(true,
                            juce::ModalCallbackFunction::create(
                                [safePanel, editor, albumId](int result)
                                {
                                    if (result == 1 && safePanel != nullptr)
                                    {
                                        const auto title = editor->getTextEditorContents("title");
                                        const auto artist = editor->getTextEditorContents("artist");
                                        if (!safePanel->musicLibrary.renameAlbum(albumId, title, artist))
                                        {
                                            juce::AlertWindow::showMessageBoxAsync(
                                                juce::MessageBoxIconType::WarningIcon,
                                                "Edit album",
                                                "Album title and artist cannot be empty.");
                                        }
                                    }

                                    delete editor;
                                }),
                            false);
}

void PlayerPanel::playAlbum(const juce::String& albumId)
{
    const auto files = musicLibrary.getPlayableFiles(albumId);
    if (files.isEmpty())
    {
        juce::AlertWindow::showMessageBoxAsync(juce::MessageBoxIconType::WarningIcon,
                                               "Play album",
                                               "This album has no available audio files.");
        return;
    }

    juce::String title;
    for (const auto& album : libraryState.albums)
    {
        if (album.id == albumId)
        {
            title = album.title;
            break;
        }
    }

    if (audioEngine.playAlbumPlaylist(albumId,
                                      title.isNotEmpty() ? title : albumId,
                                      files) <= 0)
    {
        juce::AlertWindow::showMessageBoxAsync(juce::MessageBoxIconType::WarningIcon,
                                               "Play album",
                                               "The album could not be loaded for playback.");
    }
}

void PlayerPanel::addAlbumToQueue(const juce::String& albumId)
{
    const auto files = musicLibrary.getPlayableFiles(albumId);
    if (files.isEmpty())
        return;

    audioEngine.addFiles(files, false);
}

void PlayerPanel::removeAlbum(const juce::String& albumId)
{
    musicLibrary.removeAlbum(albumId);
}

void PlayerPanel::showAlbumView()
{
    showingAlbums = true;
    playlistList.setVisible(false);
    albumBrowser.setVisible(true);
    emptyStateLabel.setVisible(false);
    playlistLabel.setText("Albums", juce::dontSendNotification);
    playlistInfoLabel.setText(juce::String(libraryState.albums.size())
                                  + (libraryState.albums.size() == 1 ? " album" : " albums"),
                              juce::dontSendNotification);
    albumsViewButton.setToggleState(true, juce::dontSendNotification);
    queueViewButton.setToggleState(false, juce::dontSendNotification);
    resized();
}

void PlayerPanel::showQueueView()
{
    showingAlbums = false;
    playlistList.setVisible(true);
    albumBrowser.setVisible(false);
    emptyStateLabel.setVisible(currentState.playlistPaths.isEmpty());
    playlistLabel.setText("Playlist", juce::dontSendNotification);
    playlistInfoLabel.setText(juce::String(currentState.playlistPaths.size())
                                  + (currentState.playlistPaths.size() == 1 ? " track" : " tracks"),
                              juce::dontSendNotification);
    albumsViewButton.setToggleState(false, juce::dontSendNotification);
    queueViewButton.setToggleState(true, juce::dontSendNotification);
    resized();
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
    const auto hasActiveTracks = currentState.hasFile;
    const auto hasQueueTracks = !currentState.playlistPaths.isEmpty();
    setTransportIcon(playButton,
                     currentState.isPlaying ? ClosureTransportIcons::pause
                                             : ClosureTransportIcons::play);
    playButton.setTooltip(currentState.isPlaying ? "Pause" : "Play");
    playButton.setName(currentState.isPlaying ? "Pause" : "Play");
    repeatButton.setButtonText(repeatModeText());
    repeatButton.setToggleState(currentState.repeatMode != AudioEngine::RepeatMode::off,
                                juce::dontSendNotification);
    gaplessButton.setButtonText(currentState.gaplessPlayback ? "Gapless: On" : "Gapless: Off");
    gaplessButton.setToggleState(currentState.gaplessPlayback, juce::dontSendNotification);
    updateVisualModeLabel();

    playButton.setEnabled(hasActiveTracks);
    previousButton.setEnabled(hasActiveTracks);
    stopButton.setEnabled(hasActiveTracks);
    nextButton.setEnabled(hasActiveTracks);
    repeatButton.setEnabled(hasActiveTracks);
    clearButton.setEnabled(hasQueueTracks);
}

void PlayerPanel::updateVisualModeLabel()
{
    visualModeButton.setButtonText(showSpectrum ? "Artwork" : "Spectrum");
    visualModeButton.setTooltip(showSpectrum ? "Show artwork" : "Show spectrum");
    visualModeButton.setName(showSpectrum ? "Show artwork" : "Show spectrum");
    visualModeButton.setToggleState(showSpectrum, juce::dontSendNotification);
}

void PlayerPanel::updateSpectrum()
{
    const auto samplesRead = audioEngine.readAnalysisSamples(analysisReadBuffer.data(),
                                                             spectrumReadSize);
    if (samplesRead > 0)
    {
        if (samplesRead >= spectrumSize)
        {
            std::memcpy(spectrumHistory.data(),
                        analysisReadBuffer.data() + samplesRead - spectrumSize,
                        static_cast<size_t>(spectrumSize) * sizeof(float));
        }
        else
        {
            std::memmove(spectrumHistory.data(),
                         spectrumHistory.data() + samplesRead,
                         static_cast<size_t>(spectrumSize - samplesRead) * sizeof(float));
            std::memcpy(spectrumHistory.data() + spectrumSize - samplesRead,
                        analysisReadBuffer.data(),
                        static_cast<size_t>(samplesRead) * sizeof(float));
        }
    }

    std::copy(spectrumHistory.begin(), spectrumHistory.end(), fftData.begin());
    spectrumWindow.multiplyWithWindowingTable(fftData.data(), spectrumSize);
    spectrumFft.performFrequencyOnlyForwardTransform(fftData.data());

    const auto maxBinExclusive = spectrumSize / 2 + 1;
    for (int bar = 0; bar < spectrumBarCount; ++bar)
    {
        const auto startRatio = static_cast<float>(bar) / static_cast<float>(spectrumBarCount);
        const auto endRatio = static_cast<float>(bar + 1) / static_cast<float>(spectrumBarCount);
        const auto lowBin = juce::jmax(1, static_cast<int>(std::floor(std::pow(maxBinExclusive, startRatio))));
        const auto highBin = juce::jmin(maxBinExclusive,
                                        juce::jmax(lowBin + 1,
                                                   static_cast<int>(std::ceil(std::pow(maxBinExclusive, endRatio)))));

        float peak = 0.0f;
        for (int bin = lowBin; bin < highBin; ++bin)
            peak = juce::jmax(peak, fftData[static_cast<size_t>(bin)] / static_cast<float>(spectrumSize));

        const auto target = juce::jlimit(0.0f, 1.0f, peak * 8.0f);
        spectrumLevels[static_cast<size_t>(bar)] = juce::jmax(target,
                                                               spectrumLevels[static_cast<size_t>(bar)] * 0.82f);
    }

    if (samplesRead == 0)
    {
        for (auto& level : spectrumLevels)
            level *= 0.92f;
    }
}

void PlayerPanel::timerCallback()
{
    updateSpectrum();
    if (showSpectrum)
        repaint(artworkBounds);
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

    return currentState.queueIsActive && index == currentState.currentTrackIndex
         ? currentState.lengthSeconds
         : 0.0;
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

void PlayerPanel::drawSpectrum(juce::Graphics& g,
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
    const auto colour = hasContent ? artworkColour(metadata->file.getFullPathName())
                                   : artworkColour(fallbackKey);
    juce::ColourGradient gradient(colour.darker(0.62f), bounds.getX(), bounds.getBottom(),
                                  colour.darker(0.28f), bounds.getRight(), bounds.getY(), true);
    g.setGradientFill(gradient);
    g.fillRect(bounds);

    const auto graph = bounds.reduced(22.0f, 24.0f);
    g.setColour(juce::Colours::white.withAlpha(0.10f));
    for (int row = 1; row < 5; ++row)
    {
        const auto y = graph.getY() + graph.getHeight() * static_cast<float>(row) / 5.0f;
        g.drawLine(graph.getX(), y, graph.getRight(), y, 1.0f);
    }

    auto graphArea = graph;
    auto labelArea = graphArea.removeFromTop(22.0f);
    g.setColour(juce::Colours::white.withAlpha(0.78f));
    g.setFont(makeFont(10.0f, true));
    g.drawText("SPECTRUM", labelArea.toNearestInt(), juce::Justification::centredLeft, false);

    const auto baseline = graphArea.getBottom() - 2.0f;
    const auto gap = 3.0f;
    const auto barWidth = juce::jmax(1.0f,
                                     (graphArea.getWidth() - gap * static_cast<float>(spectrumBarCount - 1))
                                         / static_cast<float>(spectrumBarCount));
    const auto accent = juce::Colours::white.withAlpha(hasContent ? 0.90f : 0.62f);

    for (int bar = 0; bar < spectrumBarCount; ++bar)
    {
        const auto level = spectrumLevels[static_cast<size_t>(bar)];
        const auto height = juce::jmax(3.0f, graphArea.getHeight() * (0.04f + level * 0.90f));
        const auto x = graphArea.getX() + static_cast<float>(bar) * (barWidth + gap);
        auto barBounds = juce::Rectangle<float>(x, baseline - height, barWidth, height);
        juce::ColourGradient barGradient(accent.brighter(0.12f), barBounds.getX(), barBounds.getY(),
                                          accent.darker(0.28f), barBounds.getX(), barBounds.getBottom(), false);
        g.setGradientFill(barGradient);
        g.fillRoundedRectangle(barBounds, juce::jmin(3.0f, barWidth * 0.5f));
    }

    g.setColour(juce::Colours::white.withAlpha(0.30f));
    g.drawLine(graphArea.getX(), baseline, graphArea.getRight(), baseline, 1.0f);

    if (!hasContent)
    {
        g.setColour(juce::Colours::white.withAlpha(0.72f));
        g.setFont(makeFont(13.0f));
        g.drawText("Add audio to see the spectrum",
                   graphArea.toNearestInt().withSizeKeepingCentre(static_cast<int>(graphArea.getWidth()), 26),
                   juce::Justification::centred,
                   false);
    }

    g.restoreState();
}

void PlayerPanel::drawCard(juce::Graphics& g, juce::Rectangle<float> bounds) const
{
    if (bounds.isEmpty())
        return;

    g.setColour(cardColour());
    g.fillRoundedRectangle(bounds, 10.0f);
    g.setColour(borderColour());
    g.drawRoundedRectangle(bounds, 10.0f, 1.0f);
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
    const bool isCurrent = currentState.queueIsActive
                        && trackIndex == currentState.currentTrackIndex;

    if (rowIsSelected || isCurrent)
    {
        g.setColour(GlassLookAndFeel::accent().withAlpha(rowIsSelected ? 0.13f : 0.07f));
        g.fillRoundedRectangle(row, 6.0f);
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
