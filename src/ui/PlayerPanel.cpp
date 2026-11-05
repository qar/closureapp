#include "PlayerPanel.h"
#include "audio/AudioFileFormats.h"
#include "ui/CoverArt.h"
#include "ui/icons/TransportIcons.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace
{
constexpr int outerMargin = 24;
constexpr int sectionGap = 20;
constexpr int tabBarHeight = 30;
constexpr int playbackColumnMinWidth = 320;
constexpr int playbackColumnMaxWidth = 430;
constexpr int playlistColumnMinWidth = 320;
constexpr int playbackArtworkGap = 12;
constexpr int playbackInfoHeight = 74;
constexpr int playbackInfoGap = 8;
constexpr int playbackProgressHeight = 24;
constexpr int playbackTimeGap = 4;
constexpr int playbackTimeHeight = 20;
constexpr int playbackControlGap = 8;
constexpr int playbackControlsHeight = 52;
constexpr int playbackOptionsGap = 6;
constexpr int playbackOptionsHeight = 32;
constexpr int queueRowInset = 8;
// The now-playing card casts a shadow this far outside its bounds; repaints of the
// card must cover it, or stale shadow pixels stay on screen.
constexpr int visualShadowMargin = 40;

float coverCornerRadius(float width)
{
    // Larger covers get proportionally rounder corners, capped like the album grid.
    return juce::jlimit(5.0f, 10.0f, width * 0.035f);
}

juce::Colour backgroundColour()
{
#if JUCE_MAC
    // Tint over the native behind-window blur. Lower alpha shows more of the desktop.
    return juce::Colour(0xfff3f5ef).withAlpha(0.72f);
#else
    return juce::Colour(0xfff3f5ef);
#endif
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
    // No horizontal padding, so label text lines up with the cover and slider edges.
    label.setBorderSize({ 1, 0, 1, 0 });
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

void setControlIcon(juce::DrawableButton& button,
                    const char* svg,
                    juce::Colour colour = GlassLookAndFeel::accent())
{
    const auto normal = drawableFromSvg(svg, colour);
    const auto over = drawableFromSvg(svg, colour.brighter(0.15f));
    const auto down = drawableFromSvg(svg, colour.darker(0.12f));
    button.setImages(normal.get(), over.get(), down.get());
}
}

PlayerPanel::PlayerPanel(AudioEngine& engine, MusicLibrary& library)
    : audioEngine(engine),
      musicLibrary(library),
      spectrumFft(spectrumOrder),
      spectrumWindow(spectrumSize, juce::dsp::WindowingFunction<float>::hann)
{
    setOpaque(backgroundColour().isOpaque());
    setLookAndFeel(&lookAndFeel);

    configureLabel(playlistInfoLabel, "0 tracks", 12.0f, GlassLookAndFeel::inkMuted(), false,
                   juce::Justification::centredRight);
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

    configureLabel(elapsedTimeLabel, "0:00", 12.0f, GlassLookAndFeel::inkMuted());
    configureLabel(durationTimeLabel, "0:00", 12.0f, GlassLookAndFeel::inkMuted(), false,
                   juce::Justification::centredRight);
    addAndMakeVisible(elapsedTimeLabel);
    addAndMakeVisible(durationTimeLabel);
    volumeIcon = drawableFromSvg(ClosureTransportIcons::volume, GlassLookAndFeel::inkMuted());
    if (volumeIcon != nullptr)
    {
        volumeIcon->setInterceptsMouseClicks(false, false);
        addAndMakeVisible(*volumeIcon);
    }

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

    previousButton.setComponentID("transport-previous");
    previousButton.setTooltip("Previous track");
    previousButton.setName("Previous track");
    previousButton.onClick = [this] { audioEngine.playPrevious(); };

    playButton.setComponentID("transport-play");
    playButton.setTooltip("Play");
    playButton.setName("Play");
    playButton.onClick = [this] { audioEngine.togglePlayPause(); };


    nextButton.setComponentID("transport-next");
    nextButton.setTooltip("Next track");
    nextButton.setName("Next track");
    nextButton.onClick = [this] { audioEngine.playNext(); };

    setControlIcon(previousButton, ClosureTransportIcons::previous);
    setControlIcon(playButton, ClosureTransportIcons::play);
    setControlIcon(nextButton, ClosureTransportIcons::next);
    setControlIcon(repeatButton, ClosureTransportIcons::repeat);
    previousButton.setEdgeIndent(10);
    nextButton.setEdgeIndent(10);
    playButton.setEdgeIndent(16);
    repeatButton.setEdgeIndent(6);

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

    gaplessButton.setComponentID("chip");
    gaplessButton.setTooltip("Toggle gapless playback");
    gaplessButton.setName("Gapless playback");
    gaplessButton.onClick = [this]
    {
        audioEngine.setGaplessPlayback(!currentState.gaplessPlayback);
    };

    backToAlbumsButton.setComponentID("quiet");
    backToAlbumsButton.setTooltip("Back to albums");
    backToAlbumsButton.setName("Back to albums");
    backToAlbumsButton.onClick = [this] { albumBrowser.showAlbumList(); };

    viewTabs.setName("Primary navigation");
    viewTabs.setColour(juce::TabbedButtonBar::tabOutlineColourId,
                       GlassLookAndFeel::glassStroke());
    viewTabs.setColour(juce::TabbedButtonBar::frontOutlineColourId,
                       GlassLookAndFeel::accent());
    viewTabs.setColour(juce::TabbedButtonBar::tabTextColourId,
                       GlassLookAndFeel::inkMuted());
    viewTabs.setColour(juce::TabbedButtonBar::frontTextColourId,
                       GlassLookAndFeel::inkPrimary());
    viewTabs.addTab("Albums", juce::Colours::transparentBlack, 0);
    viewTabs.addTab("Queue", juce::Colours::transparentBlack, 1);
    viewTabs.addChangeListener(this);

    addAndMakeVisible(addButton);
    addAndMakeVisible(addAlbumButton);
    addAndMakeVisible(clearButton);
    addAndMakeVisible(viewTabs);
    addAndMakeVisible(backToAlbumsButton);
    addAndMakeVisible(previousButton);
    addAndMakeVisible(playButton);
    addAndMakeVisible(nextButton);
    addAndMakeVisible(repeatButton);
    addAndMakeVisible(gaplessButton);

    playlistList.setModel(this);
    playlistList.setRowHeight(56);
    playlistList.setColour(juce::ListBox::backgroundColourId, juce::Colours::transparentBlack);
    playlistList.setColour(juce::ListBox::outlineColourId, juce::Colours::transparentBlack);
    playlistList.setOutlineThickness(0);
    playlistList.setMultipleSelectionEnabled(false);
    addAndMakeVisible(playlistList);

    albumBrowser.setPlayAlbumCallback([this](const juce::String& albumId)
    {
        playAlbum(albumId);
    });
    albumBrowser.setPlayTrackCallback([this](const juce::String& albumId,
                                             const juce::File& file)
    {
        playAlbumTrack(albumId, file);
    });
    albumBrowser.setViewChangedCallback([this]
    {
        resized();
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
    albumBrowser.setMatchMetadataCallback([this](const juce::String& albumId)
    {
        matchAlbumMetadata(albumId);
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
    startTimerHz(60);
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

    const auto visualArea = spectrumBounds.toFloat();
    if (visualArea.isEmpty())
        return;

    if (visualMode == VisualMode::spectrum)
    {
        drawSpectrum(g,
                     visualArea.reduced(8.0f),
                     currentPlaybackMetadata,
                     currentState.filePath.isNotEmpty() ? currentState.filePath : "empty-library");
    }
    else if (visualMode == VisualMode::lyrics)
    {
        drawLyrics(g, visualArea, currentPlaybackMetadata);
    }
    else
    {
        juce::DropShadow(juce::Colours::black.withAlpha(0.18f), 24, { 0, 10 })
            .drawForRectangle(g, spectrumBounds.reduced(6));
        drawArtwork(g,
                    visualArea,
                    currentPlaybackMetadata,
                    currentState.filePath.isNotEmpty() ? currentState.filePath : "empty-library");
    }
}

void PlayerPanel::resized()
{
    panelBounds = getLocalBounds().reduced(outerMargin, 20);
#if JUCE_MAC
    // Clear the traffic-light buttons in the transparent titlebar.
    panelBounds.removeFromTop(18);
#endif

    const auto showingAlbumDetails = showingAlbums && albumBrowser.isShowingDetails();
    viewTabs.setVisible(!showingAlbumDetails);
    backToAlbumsButton.setVisible(showingAlbumDetails);
    auto navigationBar = panelBounds.removeFromTop(tabBarHeight);

    panelBounds.removeFromTop(sectionGap);

    auto mainArea = panelBounds;
    const auto splitWidth = juce::jmax(0, mainArea.getWidth() - sectionGap);
    const auto leftMinimum = juce::jmin(playbackColumnMinWidth, splitWidth / 2);
    const auto leftMaximum = juce::jmin(playbackColumnMaxWidth,
                                        juce::jmax(leftMinimum,
                                                   splitWidth - playlistColumnMinWidth));
    const auto preferredLeftWidth = splitWidth * 40 / 100;
    const auto leftWidth = splitWidth > 0
                         ? juce::jlimit(leftMinimum, leftMaximum, preferredLeftWidth)
                         : 0;
    nowPlayingBounds = mainArea.removeFromLeft(leftWidth);
    mainArea.removeFromLeft(juce::jmin(sectionGap, mainArea.getWidth()));
    playlistBounds = mainArea;

    // The tabs switch the right column, so centre them over that column's content.
    if (!showingAlbumDetails)
    {
        const auto columnContent = playlistBounds.reduced(20, 0);
        viewTabs.setBounds(navigationBar.withX(columnContent.getX())
                               .withWidth(columnContent.getWidth())
                               .withSizeKeepingCentre(200, tabBarHeight));
    }

    if (showingAlbumDetails)
    {
        const auto backArea = juce::Rectangle<int>(playlistBounds.getX() + 20,
                                                   navigationBar.getY(),
                                                   160,
                                                   navigationBar.getHeight());
        backToAlbumsButton.setBounds(backArea.withSizeKeepingCentre(140, 30));
    }

    auto playbackArea = nowPlayingBounds.reduced(24, 18);

    const auto playbackReserve = playbackArtworkGap
                               + playbackInfoHeight
                               + playbackInfoGap
                               + playbackProgressHeight
                               + playbackTimeGap
                               + playbackTimeHeight
                               + playbackControlGap
                               + playbackControlsHeight
                               + playbackOptionsGap
                               + playbackOptionsHeight;
    const auto coverSize = juce::jmax(0, juce::jmin(playbackArea.getWidth(),
                                                    playbackArea.getHeight() - playbackReserve));
    // One column as wide as the cover, so text, sliders and controls share its edges.
    playbackArea = playbackArea.withSizeKeepingCentre(coverSize, playbackArea.getHeight());
    const auto artworkSlot = playbackArea.removeFromTop(coverSize);
    spectrumBounds = artworkSlot;
    const auto artworkSize = coverSize;
    artworkBounds = artworkSlot.withSizeKeepingCentre(artworkSize, artworkSize);
    playbackArea.removeFromTop(playbackArtworkGap);
    currentTitleLabel.setBounds(playbackArea.removeFromTop(28));
    currentArtistLabel.setBounds(playbackArea.removeFromTop(24));
    currentAlbumLabel.setBounds(playbackArea.removeFromTop(22));
    playbackArea.removeFromTop(playbackInfoGap);

    transportBounds = playbackArea;
    auto transport = transportBounds;
    auto progressRow = transport.removeFromTop(playbackProgressHeight);
    positionSlider.setBounds(progressRow);

    transport.removeFromTop(playbackTimeGap);
    auto timeRow = transport.removeFromTop(playbackTimeHeight);
    elapsedTimeLabel.setBounds(timeRow.removeFromLeft(72));
    durationTimeLabel.setBounds(timeRow.removeFromRight(72));

    transport.removeFromTop(playbackControlGap);
    auto controlsArea = transport.removeFromTop(playbackControlsHeight);
    // Previous / play-pause / next, symmetric around the primary play button.
    constexpr int sideButtonSize = 40;
    constexpr int playButtonSize = 52;
    constexpr int controlGap = 18;
    auto controls = controlsArea.withSizeKeepingCentre(sideButtonSize * 2 + playButtonSize + controlGap * 2,
                                                       playButtonSize);
    previousButton.setBounds(controls.removeFromLeft(sideButtonSize)
                                 .withSizeKeepingCentre(sideButtonSize, sideButtonSize));
    controls.removeFromLeft(controlGap);
    playButton.setBounds(controls.removeFromLeft(playButtonSize));
    controls.removeFromLeft(controlGap);
    nextButton.setBounds(controls.removeFromLeft(sideButtonSize)
                             .withSizeKeepingCentre(sideButtonSize, sideButtonSize));

    transport.removeFromTop(playbackOptionsGap);
    auto options = transport.removeFromTop(playbackOptionsHeight);
    repeatButton.setBounds(options.removeFromLeft(32).withSizeKeepingCentre(32, 28));
    options.removeFromLeft(6);
    gaplessButton.setBounds(options.removeFromLeft(72).withSizeKeepingCentre(72, 28));

    const auto volumeWidth = juce::jlimit(96, 150, options.getWidth() / 2);
    auto volume = options.removeFromRight(volumeWidth);
    if (volumeIcon != nullptr)
        volumeIcon->setTransformToFit(volume.removeFromLeft(16).withSizeKeepingCentre(16, 16).toFloat(),
                                      juce::RectanglePlacement::centred);
    volume.removeFromLeft(8);
    volumeSlider.setBounds(volume.withSizeKeepingCentre(volume.getWidth(), 24));

    const auto showingQueue = !showingAlbums;
    addButton.setVisible(showingQueue);
    addAlbumButton.setVisible(!showingAlbumDetails);
    clearButton.setVisible(showingQueue);
    playlistInfoLabel.setVisible(!showingAlbumDetails);

    auto playlistArea = playlistBounds.reduced(20, 18);
    if (showingAlbumDetails)
    {
        playlistArea.removeFromTop(12);
    }
    else
    {
        // Both views share one bottom action bar: actions on the left, count on the right.
        constexpr int actionHeight = 30;
        constexpr int actionWidth = 100;
        auto footer = playlistArea.removeFromBottom(actionHeight);
        playlistArea.removeFromBottom(12);

        if (showingQueue)
        {
            addButton.setBounds(footer.removeFromLeft(actionWidth));
            footer.removeFromLeft(8);
        }

        addAlbumButton.setBounds(footer.removeFromLeft(actionWidth));

        if (showingQueue)
        {
            footer.removeFromLeft(4);
            clearButton.setBounds(footer.removeFromLeft(64));
        }

        playlistInfoLabel.setBounds(footer.removeFromRight(120));
    }

    // Rows draw their highlight slightly beyond the column; their content keeps the edge.
    playlistList.setBounds(playlistArea.expanded(queueRowInset, 0));
    albumBrowser.setBounds(playlistArea.withTrimmedTop(-AlbumBrowser::contentInset)
                               .expanded(AlbumBrowser::contentInset, 0));
    emptyStateLabel.setBounds(playlistArea.reduced(16, 12));
}

void PlayerPanel::mouseUp(const juce::MouseEvent& event)
{
    const auto toggleBounds = visualMode == VisualMode::artwork ? artworkBounds : spectrumBounds;
    if (event.mouseWasDraggedSinceMouseDown()
        || event.mods.isPopupMenu()
        || !toggleBounds.contains(event.getPosition()))
    {
        return;
    }

    cycleVisualMode();
    repaint(spectrumBounds.expanded(visualShadowMargin));
}

void PlayerPanel::applyState(const AudioEngine::State& state)
{
    currentState = state;
    lyricsPositionBaseSeconds = currentState.positionSeconds;
    lyricsPositionTimestampMs = juce::Time::getMillisecondCounterHiRes();
    albumBrowser.setPlaybackState(currentState.activePlaylistId, currentState.filePath);
    rebuildPlaylistRows();
    updateCurrentTrackDisplay();

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

    elapsedTimeLabel.setText(formatTime(currentState.positionSeconds), juce::dontSendNotification);
    durationTimeLabel.setText(formatTime(currentState.lengthSeconds), juce::dontSendNotification);
    repaint();
}

void PlayerPanel::applyLibraryState(const MusicLibrary::State& state)
{
    libraryState = state;
    albumBrowser.setState(state);
    updateCurrentTrackDisplay();
    if (showingAlbums)
    {
        playlistInfoLabel.setText(juce::String(libraryState.albums.size())
                                      + (libraryState.albums.size() == 1 ? " album" : " albums"),
                                  juce::dontSendNotification);
    }
}

void PlayerPanel::updateCurrentTrackDisplay()
{
    const auto currentFile = currentState.filePath.isNotEmpty()
                           ? juce::File(currentState.filePath)
                           : juce::File{};
    currentPlaybackMetadata = metadataForFile(currentFile, currentState.currentTrackMetadata);
    scheduleLyricsFetch(currentPlaybackMetadata);

    if (currentState.filePath.isNotEmpty())
    {
        const auto metadata = currentPlaybackMetadata;
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

    repaint(spectrumBounds.expanded(visualShadowMargin));
}

void PlayerPanel::scheduleLyricsFetch(const TrackMetadataPtr& metadata)
{
    if (metadata == nullptr || metadata->hasLyrics() || metadata->file == juce::File{})
        return;

    Lyrics::Query query;
    query.title = metadata->title;
    query.artist = metadata->artist;
    query.album = metadata->album;
    query.durationSeconds = metadata->durationSeconds;
    if (!query.isValid())
        return;

    const auto path = metadata->file.getFullPathName().toStdString();
    const auto queryKey = query.cacheKey();
    const auto previousQuery = lyricsFetchKeys.find(path);
    if (previousQuery != lyricsFetchKeys.end() && previousQuery->second == queryKey)
    {
        const auto retry = lyricsRetryAfterMs.find(path);
        if (retry == lyricsRetryAfterMs.end()
            || juce::Time::getCurrentTime().toMilliseconds() < retry->second)
        {
            return;
        }
    }
    if (lyricsFetchesInFlight.find(path) != lyricsFetchesInFlight.end())
    {
        lyricsFetchKeys[path] = queryKey;
        lyricsRetryAfterMs.erase(path);
        return;
    }

    lyricsFetchKeys[path] = queryKey;
    lyricsRetryAfterMs.erase(path);
    lyricsFetchesInFlight.insert(path);
    const juce::Component::SafePointer<PlayerPanel> safePanel { this };
    lyricsClient.fetchAsync(
        std::move(query),
        [safePanel, path, queryKey](Lyrics::Result result)
        {
            if (safePanel == nullptr)
                return;

            safePanel->lyricsFetchesInFlight.erase(path);
            const auto queryIt = safePanel->lyricsFetchKeys.find(path);
            if (queryIt == safePanel->lyricsFetchKeys.end() || queryIt->second != queryKey)
            {
                safePanel->updateCurrentTrackDisplay();
                return;
            }

            if (result.hasLyrics())
            {
                safePanel->fetchedLyrics[path] = std::move(result);
                safePanel->fetchedLyricsKeys[path] = queryKey;
            }
            else if (result.error.isNotEmpty())
            {
                safePanel->lyricsRetryAfterMs[path] =
                    juce::Time::getCurrentTime().toMilliseconds() + 30000;
            }

            safePanel->updateCurrentTrackDisplay();
            safePanel->playlistList.repaint();
        });
}

void PlayerPanel::cycleVisualMode()
{
    switch (visualMode)
    {
        case VisualMode::artwork:
            visualMode = VisualMode::spectrum;
            break;
        case VisualMode::spectrum:
            visualMode = VisualMode::lyrics;
            break;
        case VisualMode::lyrics:
            visualMode = VisualMode::artwork;
            break;
    }

    repaint(spectrumBounds.expanded(visualShadowMargin));
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

void PlayerPanel::setMetadataMatching(bool matching)
{
    albumBrowser.setMetadataMatching(matching);
    viewTabs.setEnabled(!matching);
    backToAlbumsButton.setEnabled(!matching);
}

void PlayerPanel::matchAlbumMetadata(const juce::String& albumId)
{
    setMetadataMatching(true);
    const juce::Component::SafePointer<PlayerPanel> safePanel { this };
    musicLibrary.searchMetadataAsync(
        albumId,
        [safePanel, albumId](std::vector<MusicBrainz::ReleaseCandidate> candidates,
                             juce::String error) mutable
        {
            if (safePanel == nullptr)
                return;

            safePanel->setMetadataMatching(false);
            if (candidates.empty())
            {
                juce::AlertWindow::showMessageBoxAsync(
                    juce::MessageBoxIconType::WarningIcon,
                    "Match metadata",
                    error.isNotEmpty() ? error : "No MusicBrainz releases matched this album.");
                return;
            }

            juce::StringArray choices;
            for (const auto& candidate : candidates)
            {
                juce::String choice = candidate.title;
                if (candidate.artist.isNotEmpty())
                    choice << " - " << candidate.artist;

                juce::String details;
                if (candidate.date.isNotEmpty())
                    details << candidate.date;
                if (candidate.country.isNotEmpty())
                    details << (details.isEmpty() ? "" : ", ") << candidate.country;
                if (candidate.trackCount > 0)
                    details << (details.isEmpty() ? "" : ", ")
                            << juce::String(candidate.trackCount) << " tracks";
                if (candidate.status.isNotEmpty())
                    details << (details.isEmpty() ? "" : ", ") << candidate.status;
                if (candidate.disambiguation.isNotEmpty())
                    details << (details.isEmpty() ? "" : ", ") << candidate.disambiguation;

                if (details.isNotEmpty())
                    choice << " (" << details << ")";
                choices.add(choice);
            }

            auto* chooser = new juce::AlertWindow(
                "Match metadata",
                "Choose the MusicBrainz release that matches this album.",
                juce::AlertWindow::NoIcon);
            chooser->addComboBox("release", choices, "Release");
            chooser->addButton("Apply", 1, juce::KeyPress(juce::KeyPress::returnKey));
            chooser->addButton("Cancel", 0, juce::KeyPress(juce::KeyPress::escapeKey));

            chooser->enterModalState(
                true,
                juce::ModalCallbackFunction::create(
                    [safePanel,
                     chooser,
                     albumId,
                     selectedCandidates = std::move(candidates)](int result) mutable
                    {
                        if (result == 1 && safePanel != nullptr)
                        {
                            const auto* combo = chooser->getComboBoxComponent("release");
                            const auto selection = combo != nullptr
                                                 ? combo->getSelectedItemIndex()
                                                 : -1;
                            if (juce::isPositiveAndBelow(selection,
                                                         static_cast<int>(selectedCandidates.size())))
                            {
                                safePanel->setMetadataMatching(true);
                                safePanel->musicLibrary.applyMetadataAsync(
                                    albumId,
                                    selectedCandidates[static_cast<size_t>(selection)].id,
                                    [safePanel](MusicLibrary::MetadataApplyResult applyResult)
                                    {
                                        if (safePanel == nullptr)
                                            return;

                                        safePanel->setMetadataMatching(false);
                                        if (!applyResult.success)
                                        {
                                            juce::AlertWindow::showMessageBoxAsync(
                                                juce::MessageBoxIconType::WarningIcon,
                                                "Match metadata",
                                                applyResult.error);
                                            return;
                                        }

                                        juce::String message =
                                            "Album metadata was updated. "
                                            + juce::String(applyResult.updatedTracks)
                                            + " tracks matched.";
                                        if (applyResult.artworkApplied)
                                            message << " Cover art was downloaded.";

                                        juce::AlertWindow::showMessageBoxAsync(
                                            juce::MessageBoxIconType::InfoIcon,
                                            "Match metadata",
                                            message);
                                    });
                            }
                        }

                        delete chooser;
                    }),
                false);
        });
}

void PlayerPanel::playAlbum(const juce::String& albumId, int startTrackIndex)
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
                                      files,
                                      startTrackIndex) <= 0)
    {
        juce::AlertWindow::showMessageBoxAsync(juce::MessageBoxIconType::WarningIcon,
                                               "Play album",
                                               "The album could not be loaded for playback.");
    }
}

void PlayerPanel::playAlbumTrack(const juce::String& albumId, const juce::File& file)
{
    const auto files = musicLibrary.getPlayableFiles(albumId);
    for (int index = 0; index < files.size(); ++index)
    {
        if (files[index].getFullPathName().compareIgnoreCase(file.getFullPathName()) == 0)
        {
            playAlbum(albumId, index);
            return;
        }
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
    setMetadataMatching(false);
    showingAlbums = true;
    albumBrowser.showAlbumList();
    playlistList.setVisible(false);
    albumBrowser.setVisible(true);
    emptyStateLabel.setVisible(false);
    playlistInfoLabel.setText(juce::String(libraryState.albums.size())
                                  + (libraryState.albums.size() == 1 ? " album" : " albums"),
                              juce::dontSendNotification);
    viewTabs.setCurrentTabIndex(0, false);
    resized();
}

void PlayerPanel::showQueueView()
{
    setMetadataMatching(false);
    showingAlbums = false;
    playlistList.setVisible(true);
    albumBrowser.setVisible(false);
    emptyStateLabel.setVisible(currentState.playlistPaths.isEmpty());
    playlistInfoLabel.setText(juce::String(currentState.playlistPaths.size())
                                  + (currentState.playlistPaths.size() == 1 ? " track" : " tracks"),
                              juce::dontSendNotification);
    viewTabs.setCurrentTabIndex(1, false);
    resized();
}

void PlayerPanel::changeListenerCallback(juce::ChangeBroadcaster* source)
{
    if (source != &viewTabs)
        return;

    const auto newCurrentTabIndex = viewTabs.getCurrentTabIndex();
    if (newCurrentTabIndex == 0 && !showingAlbums)
        showAlbumView();
    else if (newCurrentTabIndex == 1 && showingAlbums)
        showQueueView();
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
    setControlIcon(playButton,
                   currentState.isPlaying ? ClosureTransportIcons::pause
                                           : ClosureTransportIcons::play,
                   juce::Colours::white);
    playButton.setTooltip(currentState.isPlaying ? "Pause" : "Play");
    playButton.setName(currentState.isPlaying ? "Pause" : "Play");
    const auto repeatIsOne = currentState.repeatMode == AudioEngine::RepeatMode::single;
    const auto repeatIsOff = currentState.repeatMode == AudioEngine::RepeatMode::off;
    setControlIcon(repeatButton,
                   repeatIsOne ? ClosureTransportIcons::repeatOne
                               : ClosureTransportIcons::repeat,
                   repeatIsOff ? GlassLookAndFeel::inkMuted()
                               : GlassLookAndFeel::accent());
    repeatButton.setTooltip(repeatIsOff ? "Repeat: Off"
                                        : (repeatIsOne ? "Repeat: One" : "Repeat: All"));
    repeatButton.setName(repeatIsOff ? "Repeat: Off"
                                     : (repeatIsOne ? "Repeat: One" : "Repeat: All"));
    repeatButton.setToggleState(!repeatIsOff, juce::dontSendNotification);
    gaplessButton.setButtonText("Gapless");
    gaplessButton.setTooltip(currentState.gaplessPlayback ? "Gapless playback: On"
                                                          : "Gapless playback: Off");
    gaplessButton.setToggleState(currentState.gaplessPlayback, juce::dontSendNotification);

    playButton.setEnabled(hasActiveTracks);
    previousButton.setEnabled(hasActiveTracks);
    nextButton.setEnabled(hasActiveTracks);
    repeatButton.setEnabled(hasActiveTracks);
    clearButton.setEnabled(hasQueueTracks);
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
    if (visualMode == VisualMode::spectrum)
        updateSpectrum();
    if (visualMode != VisualMode::artwork)
        repaint(spectrumBounds);
}

TrackMetadataPtr PlayerPanel::metadataAt(int index) const
{
    if (!juce::isPositiveAndBelow(index, static_cast<int>(currentState.playlistMetadata.size())))
        return nullptr;

    const auto metadata = currentState.playlistMetadata[static_cast<size_t>(index)];
    if (!juce::isPositiveAndBelow(index, currentState.playlistPaths.size()))
        return metadata;

    return metadataForFile(
        juce::File(currentState.playlistPaths[index]),
        metadata);
}

TrackMetadataPtr PlayerPanel::metadataForFile(const juce::File& file,
                                              const TrackMetadataPtr& fallback) const
{
    auto metadata = musicLibrary.metadataForPlayback(file, fallback);
    if (metadata == nullptr || metadata->hasLyrics())
        return metadata;

    const auto key = file.getFullPathName().toStdString();
    const auto lyricsIt = fetchedLyrics.find(key);
    const auto lyricsKey = fetchedLyricsKeys.find(key);
    if (lyricsIt == fetchedLyrics.end()
        || lyricsKey == fetchedLyricsKeys.end()
        || !lyricsIt->second.hasLyrics())
        return metadata;

    Lyrics::Query query;
    query.title = metadata->title;
    query.artist = metadata->artist;
    query.album = metadata->album;
    query.durationSeconds = metadata->durationSeconds;
    if (!query.isValid() || lyricsKey->second != query.cacheKey())
        return metadata;

    auto result = *metadata;
    result.lyrics = lyricsIt->second.syncedLyrics.isNotEmpty()
                  ? lyricsIt->second.syncedLyrics
                  : lyricsIt->second.plainLyrics;
    result.lyricsLines = TrackMetadataUtil::parseLyrics(result.lyrics);
    return std::make_shared<const TrackMetadata>(std::move(result));
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

void PlayerPanel::drawArtwork(juce::Graphics& g,
                              juce::Rectangle<float> bounds,
                              const TrackMetadataPtr& metadata,
                              const juce::String& fallbackKey) const
{
    const bool hasContent = metadata != nullptr && metadata->file != juce::File{};
    const auto* artwork = hasContent && metadata->hasArtwork() ? metadata->artwork.get() : nullptr;
    const auto key = hasContent ? metadata->file.getFullPathName() : fallbackKey;
    const auto title = !hasContent ? juce::String()
                     : (metadata->title.isNotEmpty() ? metadata->title
                                                     : metadata->file.getFileNameWithoutExtension());
    CoverArt::draw(g, bounds, artwork, key, title, coverCornerRadius(bounds.getWidth()));
}

void PlayerPanel::drawSpectrum(juce::Graphics& g,
                               juce::Rectangle<float> bounds,
                               const TrackMetadataPtr&,
                               const juce::String&) const
{
    if (bounds.isEmpty())
        return;

    const auto graph = bounds;
    const auto baseline = graph.getBottom();
    // Each bar takes 60% of its slot; the rest is the gap.
    const auto slot = graph.getWidth() / static_cast<float>(spectrumBarCount);
    const auto barWidth = juce::jmax(1.0f, slot * 0.6f);
    g.setColour(GlassLookAndFeel::inkPrimary().withAlpha(0.82f));

    for (int bar = 0; bar < spectrumBarCount; ++bar)
    {
        const auto level = spectrumLevels[static_cast<size_t>(bar)];
        // Silence rests as a thin baseline instead of a row of tall pills.
        const auto height = juce::jmax(2.0f, graph.getHeight() * level * 0.92f);
        const auto x = graph.getX() + static_cast<float>(bar) * slot + (slot - barWidth) * 0.5f;
        const auto barBounds = juce::Rectangle<float>(x, baseline - height, barWidth, height);
        g.fillRoundedRectangle(barBounds, juce::jmin(barWidth * 0.5f, height * 0.5f));
    }
}

void PlayerPanel::drawLyrics(juce::Graphics& g,
                             juce::Rectangle<float> bounds,
                             const TrackMetadataPtr& metadata) const
{
    if (bounds.isEmpty())
        return;

    const auto area = bounds.reduced(18.0f, 20.0f);
    if (metadata == nullptr || !metadata->hasLyrics())
    {
        g.setColour(GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(14.0f));
        g.drawFittedText("No lyrics found\nAdd embedded lyrics or a matching .lrc file",
                         area.toNearestInt(),
                         juce::Justification::centred,
                         3);
        return;
    }

    if (metadata->lyricsLines.empty())
    {
        g.setColour(GlassLookAndFeel::inkPrimary());
        g.setFont(makeFont(14.0f));
        g.drawFittedText(metadata->lyrics,
                         area.toNearestInt(),
                         juce::Justification::centred,
                         juce::jmax(1, static_cast<int>(area.getHeight() / 22.0f)));
        return;
    }

    auto positionSeconds = currentState.positionSeconds;
    if (currentState.isPlaying
        && currentState.filePath.isNotEmpty()
        && lyricsPositionTimestampMs > 0.0)
    {
        positionSeconds = lyricsPositionBaseSeconds
                        + (juce::Time::getMillisecondCounterHiRes()
                           - lyricsPositionTimestampMs) / 1000.0;
        if (currentState.lengthSeconds > 0.0)
            positionSeconds = juce::jmin(positionSeconds, currentState.lengthSeconds);
    }

    int currentLine = -1;
    int nextLine = -1;
    for (size_t index = 0; index < metadata->lyricsLines.size(); ++index)
    {
        if (metadata->lyricsLines[index].timeSeconds > positionSeconds)
        {
            nextLine = static_cast<int>(index);
            break;
        }
        currentLine = static_cast<int>(index);
    }

    const auto lineHeight = 28.0f;
    const auto visibleLines = juce::jmax(1, static_cast<int>(area.getHeight() / lineHeight));
    const auto lineCount = static_cast<int>(metadata->lyricsLines.size());
    auto focus = currentLine >= 0 ? static_cast<float>(currentLine) : 0.0f;
    float transition = 0.0f;
    if (currentLine >= 0 && nextLine >= 0)
    {
        const auto nextTime = metadata->lyricsLines[static_cast<size_t>(nextLine)].timeSeconds;
        const auto transitionStart = juce::jmax(
            metadata->lyricsLines[static_cast<size_t>(currentLine)].timeSeconds,
            nextTime - 0.4);
        const auto transitionEnd = nextTime;
        if (transitionEnd > transitionStart)
        {
            const auto normalized = static_cast<float>(juce::jlimit(
                0.0,
                1.0,
                (positionSeconds - transitionStart) / (transitionEnd - transitionStart)));
            transition = normalized * normalized * (3.0f - 2.0f * normalized);
            focus += transition;
        }
    }

    const auto centreIndex = static_cast<int>(std::floor(focus));
    const auto firstLine = juce::jmax(0, centreIndex - visibleLines);
    const auto lastLine = juce::jmin(lineCount, centreIndex + visibleLines + 1);
    const auto normalColour = GlassLookAndFeel::inkMuted().withAlpha(0.72f);
    const auto accentColour = GlassLookAndFeel::accent();

    g.saveState();
    g.reduceClipRegion(area.toNearestInt());
    for (int lineIndex = firstLine; lineIndex < lastLine; ++lineIndex)
    {
        const auto& line = metadata->lyricsLines[static_cast<size_t>(lineIndex)];
        auto highlight = 0.0f;
        if (lineIndex == currentLine)
            highlight = 1.0f - transition;
        if (lineIndex == nextLine)
            highlight = juce::jmax(highlight, transition);

        const auto lineBounds = juce::Rectangle<float>(area.getX(),
                                                       area.getCentreY()
                                                           + (static_cast<float>(lineIndex) - focus) * lineHeight
                                                           - lineHeight / 2.0f,
                                                       area.getWidth(),
                                                       lineHeight);
        g.setColour(normalColour.interpolatedWith(accentColour, highlight));
        g.setFont(makeFont(13.0f + highlight * 2.0f));
        g.drawFittedText(line.text,
                         lineBounds.toNearestInt(),
                         juce::Justification::centred,
                         1);
    }
    g.restoreState();
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
    const auto rowBounds = juce::Rectangle<float>(0.0f, 0.0f,
                                                  static_cast<float>(width),
                                                  static_cast<float>(height));
    const bool isCurrent = currentState.queueIsActive
                        && trackIndex == currentState.currentTrackIndex;

    if (rowIsSelected || isCurrent)
    {
        g.setColour(GlassLookAndFeel::accent().withAlpha(isCurrent ? 0.08f : 0.05f));
        g.fillRoundedRectangle(rowBounds.reduced(2.0f, 2.0f), 8.0f);
    }

    auto row = rowBounds.reduced(static_cast<float>(queueRowInset), 0.0f);
    const auto cover = row.removeFromLeft(40.0f).withSizeKeepingCentre(40.0f, 40.0f);
    drawArtwork(g, cover, metadataAt(trackIndex), currentState.playlistPaths[trackIndex]);
    row.removeFromLeft(12.0f);

    auto duration = row.removeFromRight(56.0f);
    g.setColour(GlassLookAndFeel::inkMuted());
    g.setFont(makeFont(12.0f));
    const auto durationSeconds = durationAt(trackIndex);
    if (durationSeconds > 0.0)
        g.drawText(formatTime(durationSeconds), duration, juce::Justification::centredRight, false);
    row.removeFromRight(12.0f);

    // Title and details form one block, centred vertically as a unit.
    constexpr float titleHeight = 18.0f;
    constexpr float detailsHeight = 16.0f;
    auto text = row.withSizeKeepingCentre(row.getWidth(), titleHeight + detailsHeight);
    g.setColour(GlassLookAndFeel::inkPrimary());
    g.setFont(makeFont(13.0f, isCurrent));
    g.drawFittedText(titleAt(trackIndex), text.removeFromTop(titleHeight).toNearestInt(),
                     juce::Justification::centredLeft, 1);

    juce::StringArray details;
    details.add(artistAt(trackIndex));
    details.add(albumAt(trackIndex));
    details.removeEmptyStrings();
    g.setColour(GlassLookAndFeel::inkMuted());
    g.setFont(makeFont(12.0f));
    g.drawFittedText(details.joinIntoString(juce::String::fromUTF8(" \xc2\xb7 ")),
                     text.toNearestInt(), juce::Justification::centredLeft, 1);
}

void PlayerPanel::listBoxItemClicked(int rowNumber, const juce::MouseEvent&)
{
    if (juce::isPositiveAndBelow(rowNumber, static_cast<int>(visibleTrackIndices.size())))
        audioEngine.playTrack(visibleTrackIndices[static_cast<size_t>(rowNumber)]);
}
