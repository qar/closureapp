#include "AlbumBrowser.h"

#include "ui/CoverArt.h"
#include "ui/GlassLookAndFeel.h"

#include <algorithm>
#include <cmath>

namespace
{
juce::Font makeFont(float size, bool bold = false)
{
    const auto font = juce::Font(juce::FontOptions(size));
    return bold ? font.boldened() : font;
}

juce::String formatTime(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0.0)
        seconds = 0.0;

    const auto total = static_cast<int>(seconds);
    return juce::String::formatted("%d:%02d", total / 60, total % 60);
}

constexpr float coverRadius = 6.0f;

void drawCover(juce::Graphics& g,
               juce::Rectangle<float> bounds,
               const std::shared_ptr<const juce::Image>& artwork,
               const juce::String& fallbackKey,
               const juce::String& title)
{
    CoverArt::draw(g, bounds, artwork.get(), fallbackKey, title, coverRadius);
}

class AlbumCard final : public juce::Component
{
public:
    static constexpr int textGap = 8;
    static constexpr int titleHeight = 18;
    static constexpr int artistHeight = 17;
    static constexpr int textHeight = textGap + titleHeight + artistHeight;

    AlbumCard(MusicLibrary::Album albumIn,
              std::function<void(const juce::String&)> onClickIn)
        : album(std::move(albumIn)), onClick(std::move(onClickIn))
    {
        setMouseCursor(juce::MouseCursor::PointingHandCursor);
        setTitle(album.title);
    }

    juce::Rectangle<float> coverBounds() const
    {
        return getLocalBounds().toFloat().withHeight(static_cast<float>(getWidth()));
    }

    void paint(juce::Graphics& g) override
    {
        const auto cover = coverBounds();
        drawCover(g, cover, thumbnailFor(cover), album.id, album.title);

        if (isMouseOverOrDragging())
        {
            g.setColour(juce::Colours::black.withAlpha(isMouseButtonDown() ? 0.16f : 0.08f));
            g.fillRoundedRectangle(cover, coverRadius);
        }

        auto text = getLocalBounds().toFloat().withTrimmedTop(cover.getHeight() + textGap);
        g.setColour(GlassLookAndFeel::inkPrimary());
        g.setFont(makeFont(13.0f, true));
        g.drawFittedText(album.title, text.removeFromTop(titleHeight).toNearestInt(),
                         juce::Justification::centredLeft, 1);
        g.setColour(GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(12.0f));
        g.drawFittedText(album.artist, text.removeFromTop(artistHeight).toNearestInt(),
                         juce::Justification::centredLeft, 1);
    }

    void mouseEnter(const juce::MouseEvent&) override { repaint(); }
    void mouseExit(const juce::MouseEvent&) override { repaint(); }
    void mouseDown(const juce::MouseEvent&) override { repaint(); }

    void mouseUp(const juce::MouseEvent& event) override
    {
        repaint();
        if (!event.mouseWasDraggedSinceMouseDown() && !event.mods.isPopupMenu() && onClick)
            onClick(album.id);
    }

private:
    /** Square-cropped, pre-scaled copy of the artwork at the on-screen pixel size.
        Scaling a full-size cover on every paint is slow and softer than one high-quality
        resample. */
    std::shared_ptr<const juce::Image> thumbnailFor(juce::Rectangle<float> cover)
    {
        const auto& source = album.artwork;
        if (source == nullptr || !source->isValid())
            return nullptr;

        const auto scale = juce::Component::getApproximateScaleFactorForComponent(this);
        const auto pixels = juce::jmax(1, juce::roundToInt(cover.getWidth() * scale));
        if (thumbnail != nullptr && thumbnailPixels == pixels)
            return thumbnail;

        const auto side = juce::jmin(source->getWidth(), source->getHeight());
        const auto square = source->getClippedImage({ (source->getWidth() - side) / 2,
                                                      (source->getHeight() - side) / 2,
                                                      side,
                                                      side });
        thumbnail = side > pixels
                  ? std::make_shared<const juce::Image>(
                        square.rescaled(pixels, pixels, juce::Graphics::highResamplingQuality))
                  : std::make_shared<const juce::Image>(square);
        thumbnailPixels = pixels;
        return thumbnail;
    }

    MusicLibrary::Album album;
    std::function<void(const juce::String&)> onClick;
    std::shared_ptr<const juce::Image> thumbnail;
    int thumbnailPixels = 0;
};
}

class AlbumBrowser::GridComponent final : public juce::Component
{
public:
    explicit GridComponent(std::function<void(const juce::String&)> onAlbumClickIn)
        : onAlbumClick(std::move(onAlbumClickIn))
    {
    }

    void setAlbums(std::vector<MusicLibrary::Album> albumsIn)
    {
        albums = std::move(albumsIn);
        cards.clear();

        for (const auto& album : albums)
        {
            auto card = std::make_unique<AlbumCard>(album, onAlbumClick);
            addAndMakeVisible(*card);
            cards.push_back(std::move(card));
        }

        resized();
        repaint();
    }

    /** Lay the grid out in a content area of `width`. Covers keep `inset` from the
        left and top edges and `rightInset` from the right edge. */
    void setLayout(int width, int rightInsetIn)
    {
        rightInset = juce::jmax(0, rightInsetIn);
        if (getWidth() == juce::jmax(1, width))
            resized();
        else
            setSize(juce::jmax(1, width), getHeight());
    }

    void paint(juce::Graphics& g) override
    {
        // Soft shadows sit in the parent so they are not clipped by each card.
        const juce::DropShadow shadow(juce::Colours::black.withAlpha(0.16f), 14, { 0, 6 });
        const auto clip = g.getClipBounds();

        for (const auto& card : cards)
        {
            const auto cover = card->getBounds().withHeight(card->getWidth()).reduced(3);
            if (cover.expanded(20).intersects(clip))
                shadow.drawForRectangle(g, cover);
        }
    }

    void resized() override
    {
        const auto width = juce::jmax(1, getWidth());
        const auto usable = juce::jmax(1, width - inset - rightInset);
        const auto columns = juce::jmax(1, (usable + columnGap) / (minCellWidth + columnGap));
        const auto cellWidth = juce::jmax(1, (usable - (columns - 1) * columnGap) / columns);
        const auto cellHeight = cellWidth + AlbumCard::textHeight;

        for (size_t index = 0; index < cards.size(); ++index)
        {
            const auto column = static_cast<int>(index % static_cast<size_t>(columns));
            const auto row = static_cast<int>(index / static_cast<size_t>(columns));
            cards[index]->setBounds(inset + column * (cellWidth + columnGap),
                                    inset + row * (cellHeight + rowGap),
                                    cellWidth,
                                    cellHeight);
        }

        const auto rows = (static_cast<int>(cards.size()) + columns - 1) / columns;
        const auto contentHeight = rows > 0 ? rows * cellHeight + (rows - 1) * rowGap : 0;
        setSize(width, juce::jmax(1, contentHeight + inset * 2));
    }

private:
    static constexpr int minCellWidth = 150;
    static constexpr int columnGap = 24;
    static constexpr int rowGap = 26;
    // Room around the grid so the outer shadows are not clipped by the viewport.
    static constexpr int inset = AlbumBrowser::contentInset;
    int rightInset = inset;

    std::vector<MusicLibrary::Album> albums;
    std::vector<std::unique_ptr<AlbumCard>> cards;
    std::function<void(const juce::String&)> onAlbumClick;
};

class AlbumBrowser::TrackListModel final : public juce::ListBoxModel
{
public:
    explicit TrackListModel(const AlbumBrowser& ownerIn) : owner(ownerIn) {}

    int getNumRows() override
    {
        const auto* album = owner.selectedAlbum();
        return album != nullptr ? static_cast<int>(album->tracks.size()) : 0;
    }

    void paintListBoxItem(int rowNumber,
                          juce::Graphics& g,
                          int width,
                          int height,
                          bool rowIsSelected) override
    {
        const auto* album = owner.selectedAlbum();
        if (album == nullptr || !juce::isPositiveAndBelow(rowNumber,
                                                          static_cast<int>(album->tracks.size())))
            return;

        const auto& track = album->tracks[static_cast<size_t>(rowNumber)];
        const auto isCurrent = owner.isCurrentTrack(track);
        if (rowIsSelected || isCurrent)
        {
            g.setColour(GlassLookAndFeel::accent().withAlpha(isCurrent ? 0.14f : 0.10f));
            g.fillRoundedRectangle(4.0f, 3.0f,
                                   static_cast<float>(width - 8),
                                   static_cast<float>(height - 6),
                                   6.0f);
        }

        if (isCurrent)
        {
            g.setColour(GlassLookAndFeel::accent());
            g.fillRoundedRectangle(4.0f, 8.0f, 3.0f,
                                   static_cast<float>(height - 16), 1.5f);
        }

        const auto number = track.trackNumber > 0 ? juce::String(track.trackNumber)
                                                  : juce::String(rowNumber + 1);
        g.setColour(isCurrent ? GlassLookAndFeel::accent()
                              : GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(11.0f));
        g.drawText(number, 10, 0, 32, height, juce::Justification::centredLeft, false);

        auto text = juce::Rectangle<int>(50, 0, width - 120, height);
        g.setColour(isCurrent ? GlassLookAndFeel::accent()
                              : (track.isAvailable() ? GlassLookAndFeel::inkPrimary()
                                                      : GlassLookAndFeel::inkMuted()));
        g.setFont(makeFont(12.0f, true));
        g.drawFittedText(track.title, text.removeFromTop(height / 2),
                         juce::Justification::centredLeft, 1);
        g.setColour(isCurrent ? GlassLookAndFeel::accent().withAlpha(0.78f)
                              : GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(11.0f));
        g.drawFittedText(track.isAvailable() ? track.artist : "File unavailable",
                         text, juce::Justification::centredLeft, 1);

        g.setColour(isCurrent ? GlassLookAndFeel::accent()
                              : GlassLookAndFeel::inkMuted());
        g.drawText(formatTime(track.durationSeconds),
                   width - 66,
                   0,
                   56,
                   height,
                   juce::Justification::centredRight,
                   false);
    }

    void listBoxItemDoubleClicked(int rowNumber, const juce::MouseEvent&) override
    {
        owner.playTrackAt(rowNumber);
    }

private:
    const AlbumBrowser& owner;
};

AlbumBrowser::AlbumBrowser()
{
    gridComponent = std::make_unique<GridComponent>([this](const juce::String& albumId)
    {
        showAlbumDetails(albumId);
    });
    gridViewport.setViewedComponent(gridComponent.get(), false);
    gridViewport.setScrollBarsShown(true, false);
    // A scrollbar appearing or disappearing changes the content width; relayout so
    // the right cover edge stays on the column edge.
    gridViewport.onVisibleAreaChanged = [this]
    {
        if (gridViewport.getMaximumVisibleWidth() != laidOutGridWidth)
            layoutGrid();
    };
    addAndMakeVisible(gridViewport);

    trackModel = std::make_unique<TrackListModel>(*this);
    trackList.setModel(trackModel.get());
    trackList.setRowHeight(52);
    trackList.setColour(juce::ListBox::backgroundColourId, juce::Colours::transparentBlack);
    trackList.setColour(juce::ListBox::outlineColourId, juce::Colours::transparentBlack);
    trackList.setOutlineThickness(0);
    addAndMakeVisible(trackList);

    detailTitle.setFont(makeFont(22.0f, true));
    detailTitle.setColour(juce::Label::textColourId, GlassLookAndFeel::inkPrimary());
    detailTitle.setInterceptsMouseClicks(false, false);
    addAndMakeVisible(detailTitle);

    detailArtist.setFont(makeFont(13.0f));
    detailArtist.setColour(juce::Label::textColourId, GlassLookAndFeel::inkMuted());
    detailArtist.setInterceptsMouseClicks(false, false);
    addAndMakeVisible(detailArtist);

    detailInfo.setFont(makeFont(12.0f));
    detailInfo.setColour(juce::Label::textColourId, GlassLookAndFeel::inkMuted());
    detailInfo.setInterceptsMouseClicks(false, false);
    addAndMakeVisible(detailInfo);

    backButton.setComponentID("quiet");
    playButton.setComponentID("primary");
    addToQueueButton.setComponentID("control");
    artworkButton.setComponentID("option");
    editButton.setComponentID("option");
    removeButton.setComponentID("quiet");
    moreButton.setComponentID("option");
    backButton.onClick = [this] { showAlbumList(); };
    playButton.onClick = [this]
    {
        if (selectedAlbumId.has_value() && playAlbumCallback)
            playAlbumCallback(*selectedAlbumId);
    };
    addToQueueButton.onClick = [this]
    {
        if (selectedAlbumId.has_value() && addToQueueCallback)
            addToQueueCallback(*selectedAlbumId);
    };
    artworkButton.onClick = [this]
    {
        if (selectedAlbumId.has_value() && chooseArtworkCallback)
            chooseArtworkCallback(*selectedAlbumId);
    };
    editButton.onClick = [this]
    {
        if (selectedAlbumId.has_value() && editAlbumCallback)
            editAlbumCallback(*selectedAlbumId);
    };
    removeButton.onClick = [this]
    {
        if (selectedAlbumId.has_value() && removeAlbumCallback)
            removeAlbumCallback(*selectedAlbumId);
    };
    moreButton.onClick = [this] { showMoreMenu(); };

    addAndMakeVisible(backButton);
    addAndMakeVisible(playButton);
    addAndMakeVisible(addToQueueButton);
    addAndMakeVisible(artworkButton);
    addAndMakeVisible(editButton);
    addAndMakeVisible(removeButton);
    addAndMakeVisible(moreButton);

    showAlbumList();
}

AlbumBrowser::~AlbumBrowser()
{
    trackList.setModel(nullptr);
    gridViewport.setViewedComponent(nullptr, false);
}

void AlbumBrowser::paint(juce::Graphics& g)
{
    g.fillAll(juce::Colours::transparentBlack);

    if (selectedAlbumId.has_value())
    {
        if (const auto* album = selectedAlbum(); album != nullptr)
        {
            drawArtwork(g, detailArtworkBounds, *album);
        }
    }
    else if (currentState.albums.empty())
    {
        g.setColour(GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(14.0f));
        g.drawFittedText("No albums yet\nAdd an album folder to start listening",
                         getLocalBounds().reduced(contentInset + 24),
                         juce::Justification::centred,
                         2);
    }
}

void AlbumBrowser::resized()
{
    if (!selectedAlbumId.has_value())
    {
        gridViewport.setBounds(getLocalBounds());
        layoutGrid();
        return;
    }

    auto area = getLocalBounds()
                    .withTrimmedLeft(contentInset)
                    .withTrimmedRight(contentInset)
                    .withTrimmedTop(contentInset)
                    .reduced(4);
    if (backButton.isVisible())
    {
        auto top = area.removeFromTop(38);
        backButton.setBounds(top.removeFromLeft(84).withSizeKeepingCentre(78, 30));
        moreButton.setBounds(top.removeFromRight(76).withSizeKeepingCentre(70, 30));
    }

    const auto detailHeight = juce::jmin(190, juce::jmax(148, area.getHeight() / 2));
    auto details = area.removeFromTop(detailHeight);
    auto artworkArea = details.removeFromLeft(164);
    const auto coverSize = juce::jmin(150, juce::jmax(0, artworkArea.getHeight() - 8));
    detailArtworkBounds = juce::Rectangle<int>(artworkArea.getCentreX() - coverSize / 2,
                                               artworkArea.getY(),
                                               coverSize,
                                               coverSize)
                              .toFloat();

    auto text = details.withTrimmedLeft(20);
    if (!backButton.isVisible())
    {
        auto titleRow = text.removeFromTop(34);
        moreButton.setBounds(titleRow.removeFromRight(84).withSizeKeepingCentre(76, 30));
        detailTitle.setBounds(titleRow);
    }
    else
    {
        detailTitle.setBounds(text.removeFromTop(34));
    }

    detailArtist.setBounds(text.removeFromTop(25));
    text.removeFromTop(10);
    detailInfo.setBounds(text.removeFromTop(24));

    auto actions = text.withTrimmedTop(12).removeFromTop(38);
    playButton.setBounds(actions.removeFromLeft(112));
    actions.removeFromLeft(8);
    addToQueueButton.setBounds(actions.removeFromLeft(120));

    trackList.setBounds(area);
}

void AlbumBrowser::layoutGrid()
{
    const auto visibleWidth = gridViewport.getMaximumVisibleWidth();
    const auto scrollbarWidth = gridViewport.getWidth() - visibleWidth;
    laidOutGridWidth = visibleWidth;
    gridComponent->setLayout(visibleWidth, contentInset - scrollbarWidth);
}

void AlbumBrowser::setState(const MusicLibrary::State& state)
{
    currentState = state;
    gridComponent->setAlbums(currentState.albums);
    refreshSelectedAlbum();
    trackList.updateContent();
    repaint();
}

void AlbumBrowser::setPlaybackState(const juce::String& playlistId,
                                    const juce::String& filePath)
{
    if (playbackPlaylistId == playlistId && playbackFilePath == filePath)
        return;

    playbackPlaylistId = playlistId;
    playbackFilePath = filePath;
    trackList.repaint();

    if (!selectedAlbumId.has_value() || playbackPlaylistId != *selectedAlbumId)
        return;

    const auto* album = selectedAlbum();
    if (album == nullptr)
        return;

    for (size_t index = 0; index < album->tracks.size(); ++index)
    {
        if (isCurrentTrack(album->tracks[index]))
        {
            trackList.scrollToEnsureRowIsOnscreen(static_cast<int>(index));
            break;
        }
    }
}

void AlbumBrowser::showAlbumList()
{
    selectedAlbumId.reset();
    setMetadataMatching(false);
    gridViewport.setVisible(true);
    trackList.setVisible(false);
    backButton.setVisible(false);
    playButton.setVisible(false);
    addToQueueButton.setVisible(false);
    artworkButton.setVisible(false);
    editButton.setVisible(false);
    removeButton.setVisible(false);
    moreButton.setVisible(false);
    detailTitle.setVisible(false);
    detailArtist.setVisible(false);
    detailInfo.setVisible(false);
    resized();
    repaint();
    if (viewChangedCallback)
        viewChangedCallback();
}

void AlbumBrowser::setPlayAlbumCallback(AlbumCallback callback)
{
    playAlbumCallback = std::move(callback);
}

void AlbumBrowser::setPlayTrackCallback(TrackCallback callback)
{
    playTrackCallback = std::move(callback);
}

void AlbumBrowser::setViewChangedCallback(std::function<void()> callback)
{
    viewChangedCallback = std::move(callback);
}

void AlbumBrowser::setAddToQueueCallback(AlbumCallback callback)
{
    addToQueueCallback = std::move(callback);
}

void AlbumBrowser::setChooseArtworkCallback(AlbumCallback callback)
{
    chooseArtworkCallback = std::move(callback);
}

void AlbumBrowser::setEditAlbumCallback(AlbumCallback callback)
{
    editAlbumCallback = std::move(callback);
}

void AlbumBrowser::setRemoveAlbumCallback(AlbumCallback callback)
{
    removeAlbumCallback = std::move(callback);
}

void AlbumBrowser::setMatchMetadataCallback(AlbumCallback callback)
{
    matchMetadataCallback = std::move(callback);
}

void AlbumBrowser::setMetadataMatching(bool matching)
{
    moreButton.setButtonText(matching ? "Matching..." : "More");
    moreButton.setEnabled(!matching);
    backButton.setEnabled(!matching);
}

void AlbumBrowser::showAlbumDetails(const juce::String& albumId)
{
    selectedAlbumId = albumId;
    setMetadataMatching(false);
    refreshSelectedAlbum();
    gridViewport.setVisible(false);
    trackList.setVisible(true);
    backButton.setVisible(false);
    playButton.setVisible(true);
    addToQueueButton.setVisible(true);
    artworkButton.setVisible(false);
    editButton.setVisible(false);
    removeButton.setVisible(false);
    moreButton.setVisible(true);
    detailTitle.setVisible(true);
    detailArtist.setVisible(true);
    detailInfo.setVisible(true);
    resized();
    repaint();
    if (viewChangedCallback)
        viewChangedCallback();
}

void AlbumBrowser::showMoreMenu()
{
    juce::PopupMenu menu;
    menu.addItem(1, "Edit details", true, false);
    menu.addItem(2, "Change cover", true, false);
    menu.addItem(3, "Match metadata", true, false);
    menu.addSeparator();
    menu.addItem(4, "Remove album", true, false);

    const juce::Component::SafePointer<AlbumBrowser> safeBrowser { this };
    menu.showMenuAsync(juce::PopupMenu::Options().withTargetComponent(&moreButton),
                       [safeBrowser](int result)
    {
        if (safeBrowser == nullptr || !safeBrowser->selectedAlbumId.has_value())
            return;

        const auto& albumId = *safeBrowser->selectedAlbumId;
        switch (result)
        {
            case 1:
                if (safeBrowser->editAlbumCallback)
                    safeBrowser->editAlbumCallback(albumId);
                break;
            case 2:
                if (safeBrowser->chooseArtworkCallback)
                    safeBrowser->chooseArtworkCallback(albumId);
                break;
            case 3:
                if (safeBrowser->matchMetadataCallback)
                    safeBrowser->matchMetadataCallback(albumId);
                break;
            case 4:
                if (safeBrowser->removeAlbumCallback)
                    safeBrowser->removeAlbumCallback(albumId);
                break;
            default:
                break;
        }
    });
}

void AlbumBrowser::playTrackAt(int rowNumber) const
{
    const auto* album = selectedAlbum();
    if (album == nullptr
        || !juce::isPositiveAndBelow(rowNumber, static_cast<int>(album->tracks.size()))
        || !selectedAlbumId.has_value())
    {
        return;
    }

    const auto& track = album->tracks[static_cast<size_t>(rowNumber)];
    if (track.isAvailable() && playTrackCallback)
        playTrackCallback(*selectedAlbumId, track.file);
}

void AlbumBrowser::refreshSelectedAlbum()
{
    if (!selectedAlbumId.has_value())
        return;

    const auto* album = selectedAlbum();
    if (album == nullptr)
    {
        showAlbumList();
        return;
    }

    detailTitle.setText(album->title, juce::dontSendNotification);
    detailArtist.setText(album->artist, juce::dontSendNotification);
    detailInfo.setText(juce::String(album->availableTrackCount()) + " of "
                           + juce::String(album->tracks.size()) + " tracks available",
                       juce::dontSendNotification);
    playButton.setEnabled(album->hasAvailableTracks());
    addToQueueButton.setEnabled(album->hasAvailableTracks());
    trackList.updateContent();
}

const MusicLibrary::Album* AlbumBrowser::selectedAlbum() const
{
    if (!selectedAlbumId.has_value())
        return nullptr;

    const auto it = std::find_if(currentState.albums.begin(), currentState.albums.end(),
                                 [this](const auto& album)
    {
        return album.id == *selectedAlbumId;
    });
    return it != currentState.albums.end() ? &*it : nullptr;
}

bool AlbumBrowser::isCurrentTrack(const MusicLibrary::Track& track) const
{
    return selectedAlbumId.has_value()
        && playbackPlaylistId == *selectedAlbumId
        && playbackFilePath.isNotEmpty()
        && track.file.getFullPathName().compareIgnoreCase(playbackFilePath) == 0;
}

void AlbumBrowser::drawArtwork(juce::Graphics& g,
                               juce::Rectangle<float> bounds,
                               const MusicLibrary::Album& album) const
{
    drawCover(g, bounds, album.artwork, album.id, album.title);
}
