#include <JuceHeader.h>
#include "audio/GaplessPlaylistSource.h"
#include "audio/TrackMetadata.h"
#include "library/MusicLibrary.h"
#include "ui/AlbumBrowser.h"

#include <cmath>
#include <cstdio>
#include <memory>

namespace
{
bool expect(bool condition, const char* message)
{
    if (!condition)
        std::fprintf(stderr, "FAIL: %s\n", message);

    return condition;
}

bool writeConstantWav(const juce::File& file, float value, int numSamples)
{
    std::unique_ptr<juce::OutputStream> output { file.createOutputStream().release() };
    if (output == nullptr)
        return false;

    juce::WavAudioFormat format;
    const auto options = juce::AudioFormatWriterOptions{}
        .withSampleRate(44100.0)
        .withNumChannels(1)
        .withBitsPerSample(32)
        .withSampleFormat(juce::AudioFormatWriterOptions::SampleFormat::floatingPoint);
    auto writer = format.createWriterFor(output, options);
    if (writer == nullptr)
        return false;

    juce::AudioBuffer<float> samples(1, numSamples);
    samples.clear();
    for (int sample = 0; sample < numSamples; ++sample)
        samples.setSample(0, sample, value);
    return writer->writeFromAudioSampleBuffer(samples, 0, numSamples);
}

bool verifyValue(const juce::AudioBuffer<float>& buffer,
                 int start,
                 int count,
                 float expected)
{
    for (int sample = start; sample < start + count; ++sample)
    {
        if (std::abs(buffer.getSample(0, sample) - expected) > 0.0001f)
            return false;
    }

    return true;
}

bool writeCoverPng(const juce::File& file)
{
    juce::Image image(juce::Image::RGB, 16, 16, true);
    juce::Graphics graphics(image);
    graphics.fillAll(juce::Colours::darkred);

    auto output = file.createOutputStream();
    if (output == nullptr || !output->openedOk())
        return false;

    juce::PNGImageFormat format;
    return format.writeImageToStream(image, *output);
}

bool testAlbumBrowserGridLayout()
{
    MusicLibrary::Album album;
    album.id = "layout-test-album";
    album.title = "Layout Test";
    album.artist = "Test Artist";

    MusicLibrary::State state;
    state.albums.push_back(album);

    AlbumBrowser browser;
    browser.setBounds(0, 0, 520, 320);
    browser.setState(state);
    browser.showAlbumList();

    auto* viewport = dynamic_cast<juce::Viewport*>(browser.getChildComponent(0));
    if (!expect(viewport != nullptr, "album browser has a grid viewport"))
        return false;

    auto* grid = viewport->getViewedComponent();
    const auto gridWidth = grid != nullptr ? grid->getWidth() : 0;
    const auto cardWidth = grid != nullptr && grid->getNumChildComponents() > 0
                         ? grid->getChildComponent(0)->getWidth()
                         : 0;
    return expect(gridWidth >= 400, "album grid matches the viewport width")
        && expect(cardWidth >= 150, "album card remains visible in the grid");
}

bool testMusicLibrary()
{
    const auto root = juce::File::getSpecialLocation(juce::File::tempDirectory)
        .getChildFile("closure-music-library-tests");
    root.deleteRecursively();
    if (!expect(root.createDirectory(), "create library test directory"))
        return false;

    const auto albumFolder = root.getChildFile("Test Album");
    const auto discFolder = albumFolder.getChildFile("Disc 2");
    if (!expect(albumFolder.createDirectory(), "create album folder")
        || !expect(discFolder.createDirectory(), "create nested album folder"))
    {
        root.deleteRecursively();
        return false;
    }

    const auto first = albumFolder.getChildFile("01 First.wav");
    const auto second = discFolder.getChildFile("01 Second.wav");
    if (!expect(writeConstantWav(first, 0.25f, 8), "write first library fixture")
        || !expect(writeConstantWav(second, 0.75f, 8), "write second library fixture"))
    {
        root.deleteRecursively();
        return false;
    }

    const auto storage = root.getChildFile("storage");
    juce::String albumId;
    bool passed = true;
    {
        MusicLibrary library(storage);
        const auto result = library.addAlbum(albumFolder);
        passed = expect(result.success, "add an album folder")
              && expect(result.addedTracks == 2, "scan nested album tracks")
              && expect(library.getState().albums.size() == 1, "library contains one album")
              && expect(storage.getChildFile("library.xml").existsAsFile(),
                         "save library to disk");

        const auto state = library.getState();
        if (!state.albums.empty())
        {
            albumId = state.albums.front().id;
            passed = expect(library.getPlayableFiles(albumId).size() == 2,
                            "return available album files")
                  && passed;

            const auto cover = root.getChildFile("cover.png");
            passed = expect(writeCoverPng(cover), "write album cover fixture") && passed;
            passed = expect(library.setCustomArtwork(albumId, cover),
                            "set custom album cover") && passed;
            const auto coveredState = library.getState();
            passed = expect(coveredState.albums.front().customArtwork
                               && coveredState.albums.front().artwork != nullptr,
                            "keep custom album cover in state") && passed;
        }

        const auto duplicate = library.addAlbum(albumFolder);
        passed = expect(!duplicate.success, "reject duplicate album folders") && passed;
    }

    second.deleteFile();
    {
        MusicLibrary restored(storage);
        const auto state = restored.getState();
        passed = expect(state.albums.size() == 1, "restore the saved album") && passed;
        passed = expect(!albumId.isEmpty() && state.albums.front().id == albumId,
                        "preserve album identity") && passed;
        passed = expect(state.albums.front().availableTrackCount() == 1,
                        "preserve missing tracks in the album") && passed;
        passed = expect(state.albums.front().customArtwork
                           && state.albums.front().artwork != nullptr,
                        "restore cached custom cover") && passed;
        passed = expect(restored.removeAlbum(albumId), "remove the album") && passed;
        passed = expect(restored.getState().albums.empty(), "remove album from library") && passed;
    }

    passed = expect(writeConstantWav(second, 0.75f, 8), "restore source fixture") && passed;
    passed = expect(first.existsAsFile() && second.existsAsFile(),
                    "removing an album keeps source audio files") && passed;
    root.deleteRecursively();
    return passed;
}

} // namespace

int main()
{
    juce::ScopedJuceInitialiser_GUI juceInitialiser;

    juce::StringPairArray metadataValues;
    metadataValues.set("ID3TITLE", "Tagged title");
    metadataValues.set("IART", "Tagged artist");
    if (!expect(TrackMetadataUtil::firstValue(metadataValues, { "id3title" }) == "Tagged title",
                "metadata keys are matched case-insensitively")
        || !expect(TrackMetadataUtil::firstValue(metadataValues, { "missing", "IART" }) == "Tagged artist",
                   "metadata aliases fall back in order"))
    {
        return 1;
    }

    const auto fallback = TrackMetadataUtil::fallbackForFile(juce::File("/tmp/Fallback Song.flac"));
    if (!expect(fallback.title == "Fallback Song", "metadata fallback uses the file name")
        || !expect(fallback.artist == "Unknown Artist", "metadata fallback has an artist label")
        || !expect(fallback.album == "Local Files", "metadata fallback has a local album label"))
    {
        return 1;
    }

    if (!testMusicLibrary())
        return 1;

    if (!testAlbumBrowserGridLayout())
        return 1;

    const auto root = juce::File::getSpecialLocation(juce::File::tempDirectory)
        .getChildFile("closure-gapless-playlist-tests");
    root.deleteRecursively();
    if (!expect(root.createDirectory(), "create temporary test directory"))
        return 1;

    const auto first = root.getChildFile("first.wav");
    const auto second = root.getChildFile("second.wav");
    if (!expect(writeConstantWav(first, 0.25f, 8), "write first fixture")
        || !expect(writeConstantWav(second, 0.75f, 8), "write second fixture"))
    {
        return 1;
    }

    juce::AudioFormatManager formatManager;
    formatManager.registerBasicFormats();
    juce::TimeSliceThread readAheadThread("Gapless playlist test read ahead");
    readAheadThread.startThread();

    GaplessPlaylistSource source(formatManager, readAheadThread);
    juce::Array<juce::File> files { first, second };
    const auto added = source.addFiles(files);
    if (!expect(added == 2, "add two tracks")
        || !expect(source.addFiles(files) == 0, "ignore duplicate tracks"))
    {
        return 1;
    }

    source.setLooping(false);
    source.prepareToPlay(16, 44100.0);
    source.selectTrack(0);

    juce::AudioBuffer<float> output(1, 16);
    output.clear();
    source.getNextAudioBlock({ &output, 0, output.getNumSamples() });

    const auto firstState = source.getState();
    bool passed = expect(verifyValue(output, 0, 8, 0.25f), "first track has no corruption")
               && expect(verifyValue(output, 8, 8, 0.75f), "second track starts in the same block")
               && expect(firstState.currentTrackIndex == 1, "current track advances at boundary")
               && expect(firstState.trackPaths.size() == 2
                          && firstState.trackPaths[0] == first.getFullPathName(),
                          "playlist state keeps track paths for metadata");

    source.setLooping(true);
    source.selectTrack(0);
    output.setSize(1, 24);
    output.clear();
    source.getNextAudioBlock({ &output, 0, output.getNumSamples() });

    passed = expect(verifyValue(output, 0, 8, 0.25f), "loop starts with first track")
          && expect(verifyValue(output, 8, 8, 0.75f), "loop reaches second track")
          && expect(verifyValue(output, 16, 8, 0.25f), "loop returns without a silent block")
          && passed;

    readAheadThread.stopThread(2000);
    root.deleteRecursively();
    return passed ? 0 : 1;
}
