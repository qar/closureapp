#include <AVFoundation/AVFoundation.h>

#include "TrackMetadata.h"

#include <memory>

namespace
{
int parseNumber(const juce::String& value)
{
    return value.upToFirstOccurrenceOf("/", false, false).trim().getIntValue();
}
}

namespace
{
void applyFallback(TrackMetadata& metadata, const juce::StringPairArray& values)
{
    const auto title = TrackMetadataUtil::firstValue(values, { "id3title", "INAM" });
    const auto artist = TrackMetadataUtil::firstValue(values, { "id3artist", "IART" });
    const auto albumArtist = TrackMetadataUtil::firstValue(values,
                                                           { "id3albumartist", "TPE2", "aART" });
    const auto album = TrackMetadataUtil::firstValue(values, { "id3album", "IPRD" });
    const auto genre = TrackMetadataUtil::firstValue(values, { "id3genre", "GENR" });
    const auto discNumber = TrackMetadataUtil::firstValue(values,
                                                          { "id3discnumber", "TPOS", "DISK" });
    const auto trackNumber = TrackMetadataUtil::firstValue(values,
                                                           { "id3tracknumber", "TRCK", "TRACK" });

    if (title.isNotEmpty())
        metadata.title = title;
    if (artist.isNotEmpty())
        metadata.artist = artist;
    if (albumArtist.isNotEmpty())
        metadata.albumArtist = albumArtist;
    if (album.isNotEmpty())
        metadata.album = album;
    if (genre.isNotEmpty())
        metadata.genre = genre;
    if (discNumber.isNotEmpty())
        metadata.discNumber = parseNumber(discNumber);
    if (trackNumber.isNotEmpty())
        metadata.trackNumber = parseNumber(trackNumber);
}

void applyCommonMetadata(TrackMetadata& metadata, NSArray<AVMetadataItem*>* items)
{
    for (AVMetadataItem* item in items)
    {
        if ([item.commonKey isEqualToString:AVMetadataCommonKeyTitle]
            && item.stringValue.length > 0)
        {
            metadata.title = juce::String::fromUTF8(item.stringValue.UTF8String);
        }
        else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtist]
                 && item.stringValue.length > 0)
        {
            metadata.artist = juce::String::fromUTF8(item.stringValue.UTF8String);
        }
        else if ([item.identifier isEqualToString:AVMetadataIdentifieriTunesMetadataAlbumArtist]
                 && item.stringValue.length > 0)
        {
            metadata.albumArtist = juce::String::fromUTF8(item.stringValue.UTF8String);
        }
        else if ([item.commonKey isEqualToString:AVMetadataCommonKeyAlbumName]
                 && item.stringValue.length > 0)
        {
            metadata.album = juce::String::fromUTF8(item.stringValue.UTF8String);
        }
        else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtwork]
                 && item.dataValue.length > 0
                 && item.dataValue.length <= 16 * 1024 * 1024)
        {
            const auto image = juce::ImageFileFormat::loadFrom(item.dataValue.bytes,
                                                                item.dataValue.length);
            if (image.isValid())
                metadata.artwork = std::make_shared<const juce::Image>(image);
        }
    }
}

TrackMetadata readMetadata(const juce::File& file)
{
    auto metadata = TrackMetadataUtil::fallbackForFile(file);

    juce::AudioFormatManager formatManager;
    formatManager.registerBasicFormats();

    if (auto reader = std::unique_ptr<juce::AudioFormatReader>(
            formatManager.createReaderFor(file)) )
    {
        if (reader->sampleRate > 0.0)
            metadata.durationSeconds = static_cast<double>(reader->lengthInSamples) / reader->sampleRate;

        applyFallback(metadata, reader->metadataValues);
    }

    @autoreleasepool
    {
        NSString* path = [NSString stringWithUTF8String:file.getFullPathName().toRawUTF8()];
        NSURL* url = [NSURL fileURLWithPath:path];
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
        applyCommonMetadata(metadata, asset.commonMetadata);
    }

    return metadata;
}
}

class TrackMetadataReader::Job final : public juce::ThreadPoolJob
{
public:
    Job(juce::File fileIn,
        Callback callbackIn,
        std::shared_ptr<std::atomic_bool> lifetimeIn)
        : ThreadPoolJob("Read track metadata"),
          file(std::move(fileIn)),
          callback(std::move(callbackIn)),
          lifetime(std::move(lifetimeIn))
    {
    }

    JobStatus runJob() override
    {
        auto result = readMetadata(file);
        auto lifetimeCopy = lifetime;
        auto callbackForMessage = callback;

        juce::MessageManager::callAsync([lifetimeCopy,
                                          messageCallback = std::move(callbackForMessage),
                                          messageResult = std::move(result)]() mutable
        {
            if (lifetimeCopy->load() && messageCallback)
                messageCallback(std::move(messageResult));
        });

        return jobHasFinished;
    }

private:
    juce::File file;
    Callback callback;
    std::shared_ptr<std::atomic_bool> lifetime;
};

TrackMetadataReader::TrackMetadataReader()
    : lifetime(std::make_shared<std::atomic_bool>(true))
{
}

TrackMetadataReader::~TrackMetadataReader()
{
    lifetime->store(false);
    threadPool.removeAllJobs(true, 2000);
}

void TrackMetadataReader::readAsync(const juce::File& file, Callback callback)
{
    if (file == juce::File{} || !callback)
        return;

    threadPool.addJob(new Job(file, std::move(callback), lifetime), true);
}
