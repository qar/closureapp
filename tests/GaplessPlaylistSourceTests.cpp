#include <JuceHeader.h>
#include "audio/GaplessPlaylistSource.h"
#include "audio/TrackMetadata.h"

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
} // namespace

int main()
{
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
