#include "AlbumBrowser.h"

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

juce::Colour artworkColour(const juce::String& key)
{
    const auto hash = static_cast<uint32_t>(key.hashCode());
    const auto hue = static_cast<float>(hash % 1000u) / 1000.0f;
    return juce::Colour::fromHSV(hue, 0.48f, 0.86f, 1.0f);
}

juce::String formatTime(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0.0)
        seconds = 0.0;

    const auto total = static_cast<int>(seconds);
    return juce::String::formatted("%d:%02d", total / 60, total % 60);
}

void drawCover(juce::Graphics& g,
               juce::Rectangle<float> bounds,
               const std::shared_ptr<const juce::Image>& artwork,
               const juce::String& fallbackKey)
{
    if (bounds.isEmpty())
        return;

    juce::Path clip;
    clip.addRoundedRectangle(bounds, 8.0f);
    g.saveState();
    g.reduceClipRegion(clip);

    if (artwork != nullptr && artwork->isValid())
    {
        g.drawImageWithin(*artwork,
                          static_cast<int>(bounds.getX()),
                          static_cast<int>(bounds.getY()),
                          static_cast<int>(bounds.getWidth()),
                          static_cast<int>(bounds.getHeight()),
                          juce::RectanglePlacement::centred | juce::RectanglePlacement::fillDestination,
                          false);
        g.restoreState();
        return;
    }

    const auto colour = artworkColour(fallbackKey);
    g.setGradientFill(juce::ColourGradient(colour.brighter(0.18f),
                                            bounds.getX(),
                                            bounds.getY(),
                                            colour.darker(0.18f),
                                            bounds.getRight(),
                                            bounds.getBottom(),
                                            true));
    g.fillRect(bounds);

    const auto centre = bounds.getCentre();
    const auto radius = juce::jmin(bounds.getWidth(), bounds.getHeight()) * 0.19f;
    g.setColour(juce::Colours::white.withAlpha(0.72f));
    g.drawEllipse(centre.x - radius, centre.y - radius, radius * 2.0f, radius * 2.0f, 3.0f);
    g.fillEllipse(centre.x - 5.0f, centre.y - 5.0f, 10.0f, 10.0f);
    g.drawLine(centre.x + radius * 0.72f,
               centre.y - radius * 0.72f,
               centre.x + radius * 0.72f,
               centre.y - radius * 1.65f,
               3.0f);
    g.restoreState();
}

class AlbumCard final : public juce::Component
{
public:
    AlbumCard(MusicLibrary::Album albumIn,
              std::function<void(const juce::String&)> onClickIn)
        : album(std::move(albumIn)), onClick(std::move(onClickIn))
    {
        setMouseCursor(juce::MouseCursor::PointingHandCursor);
    }

    void paint(juce::Graphics& g) override
    {
        const auto bounds = getLocalBounds().toFloat();
        g.setColour(GlassLookAndFeel::glassFill());
        g.fillRoundedRectangle(bounds, 8.0f);
        g.setColour(GlassLookAndFeel::glassStroke());
        g.drawRoundedRectangle(bounds, 8.0f, 1.0f);

        const auto cover = bounds.reduced(10.0f).withTrimmedBottom(bounds.getHeight() - 138.0f);
        drawCover(g, cover, album.artwork, album.id);

        auto text = bounds.reduced(12.0f, 10.0f);
        text.removeFromTop(136.0f);
        auto title = text.removeFromTop(22.0f);
        auto artist = text.removeFromTop(19.0f);
        auto count = text;

        g.setColour(GlassLookAndFeel::inkPrimary());
        g.setFont(makeFont(13.0f, true));
        g.drawFittedText(album.title, title.toNearestInt(), juce::Justification::centredLeft, 1);
        g.setColour(GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(11.0f));
        g.drawFittedText(album.artist, artist.toNearestInt(), juce::Justification::centredLeft, 1);
        g.drawText(juce::String(album.tracks.size()) + " tracks",
                   count.toNearestInt(),
                   juce::Justification::centredLeft,
                   false);
    }

    void mouseUp(const juce::MouseEvent& event) override
    {
        if (!event.mouseWasDraggedSinceMouseDown() && !event.mods.isPopupMenu() && onClick)
            onClick(album.id);
    }

private:
    MusicLibrary::Album album;
    std::function<void(const juce::String&)> onClick;
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

    void setAvailableWidth(int width)
    {
        setSize(juce::jmax(1, width), getHeight());
    }

    void resized() override
    {
        const auto width = juce::jmax(1, getWidth());
        const auto columns = juce::jmax(1, width / 176);
        const auto gap = 14;
        const auto cardWidth = juce::jmax(150, (width - (columns - 1) * gap) / columns);
        const auto cardHeight = 190;

        for (size_t index = 0; index < cards.size(); ++index)
        {
            const auto column = static_cast<int>(index % static_cast<size_t>(columns));
            const auto row = static_cast<int>(index / static_cast<size_t>(columns));
            cards[index]->setBounds(column * (cardWidth + gap),
                                    row * (cardHeight + gap),
                                    cardWidth,
                                    cardHeight);
        }

        const auto rows = (static_cast<int>(cards.size()) + columns - 1) / columns;
        setSize(width, juce::jmax(1, rows * (cardHeight + gap) - gap));
    }

private:
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
        if (rowIsSelected)
        {
            g.setColour(GlassLookAndFeel::accent().withAlpha(0.10f));
            g.fillRoundedRectangle(4.0f, 3.0f,
                                   static_cast<float>(width - 8),
                                   static_cast<float>(height - 6),
                                   6.0f);
        }

        const auto number = track.trackNumber > 0 ? juce::String(track.trackNumber)
                                                  : juce::String(rowNumber + 1);
        g.setColour(GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(11.0f));
        g.drawText(number, 10, 0, 32, height, juce::Justification::centredLeft, false);

        auto text = juce::Rectangle<int>(50, 0, width - 120, height);
        g.setColour(track.isAvailable() ? GlassLookAndFeel::inkPrimary()
                                        : GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(12.0f, true));
        g.drawFittedText(track.title, text.removeFromTop(height / 2),
                         juce::Justification::centredLeft, 1);
        g.setColour(GlassLookAndFeel::inkMuted());
        g.setFont(makeFont(11.0f));
        g.drawFittedText(track.isAvailable() ? track.artist : "File unavailable",
                         text, juce::Justification::centredLeft, 1);

        g.drawText(formatTime(track.durationSeconds),
                   width - 66,
                   0,
                   56,
                   height,
                   juce::Justification::centredRight,
                   false);
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

    addAndMakeVisible(backButton);
    addAndMakeVisible(playButton);
    addAndMakeVisible(addToQueueButton);
    addAndMakeVisible(artworkButton);
    addAndMakeVisible(editButton);
    addAndMakeVisible(removeButton);

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
                         getLocalBounds().reduced(24),
                         juce::Justification::centred,
                         2);
    }
}

void AlbumBrowser::resized()
{
    if (!selectedAlbumId.has_value())
    {
        gridViewport.setBounds(getLocalBounds());
        gridComponent->setAvailableWidth(gridViewport.getMaximumVisibleWidth());
        return;
    }

    auto area = getLocalBounds().reduced(4);
    auto top = area.removeFromTop(38);
    backButton.setBounds(top.removeFromLeft(84).withSizeKeepingCentre(78, 30));
    removeButton.setBounds(top.removeFromRight(76).withSizeKeepingCentre(70, 30));
    artworkButton.setBounds(top.removeFromRight(112).withSizeKeepingCentre(106, 30));
    editButton.setBounds(top.removeFromRight(106).withSizeKeepingCentre(100, 30));

    const auto detailHeight = juce::jmin(218, juce::jmax(148, area.getHeight() / 2));
    auto details = area.removeFromTop(detailHeight);
    auto artworkArea = details.removeFromLeft(164);
    const auto coverSize = juce::jmin(150, juce::jmax(0, artworkArea.getHeight() - 8));
    detailArtworkBounds = artworkArea.withSizeKeepingCentre(coverSize, coverSize).toFloat();

    detailTitle.setBounds(details.withTrimmedLeft(20).removeFromTop(32));
    detailArtist.setBounds(details.withTrimmedLeft(20).withTrimmedTop(38).removeFromTop(25));
    detailInfo.setBounds(details.withTrimmedLeft(20).withTrimmedTop(68).removeFromTop(24));

    auto actions = details.withTrimmedLeft(20).withTrimmedTop(108).removeFromTop(38);
    playButton.setBounds(actions.removeFromLeft(112));
    actions.removeFromLeft(8);
    addToQueueButton.setBounds(actions.removeFromLeft(120));

    trackList.setBounds(area);
}

void AlbumBrowser::setState(const MusicLibrary::State& state)
{
    currentState = state;
    gridComponent->setAlbums(currentState.albums);
    refreshSelectedAlbum();
    trackList.updateContent();
    repaint();
}

void AlbumBrowser::showAlbumList()
{
    selectedAlbumId.reset();
    gridViewport.setVisible(true);
    trackList.setVisible(false);
    backButton.setVisible(false);
    playButton.setVisible(false);
    addToQueueButton.setVisible(false);
    artworkButton.setVisible(false);
    editButton.setVisible(false);
    removeButton.setVisible(false);
    detailTitle.setVisible(false);
    detailArtist.setVisible(false);
    detailInfo.setVisible(false);
    resized();
    repaint();
}

void AlbumBrowser::setPlayAlbumCallback(AlbumCallback callback)
{
    playAlbumCallback = std::move(callback);
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

void AlbumBrowser::showAlbumDetails(const juce::String& albumId)
{
    selectedAlbumId = albumId;
    refreshSelectedAlbum();
    gridViewport.setVisible(false);
    trackList.setVisible(true);
    backButton.setVisible(true);
    playButton.setVisible(true);
    addToQueueButton.setVisible(true);
    artworkButton.setVisible(true);
    editButton.setVisible(true);
    removeButton.setVisible(true);
    detailTitle.setVisible(true);
    detailArtist.setVisible(true);
    detailInfo.setVisible(true);
    resized();
    repaint();
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

void AlbumBrowser::drawArtwork(juce::Graphics& g,
                               juce::Rectangle<float> bounds,
                               const MusicLibrary::Album& album) const
{
    drawCover(g, bounds, album.artwork, album.id);
}
