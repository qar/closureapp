#include "TrackMetadata.h"

#include <algorithm>
#include <cmath>

namespace
{
juce::String trimValue(juce::String value)
{
    return value.trim();
}
}

namespace TrackMetadataUtil
{
juce::String firstValue(const juce::StringPairArray& values,
                        std::initializer_list<const char*> keys)
{
    for (const auto* key : keys)
    {
        for (int i = 0; i < values.size(); ++i)
        {
            if (values.getAllKeys()[i].equalsIgnoreCase(key))
            {
                const auto value = trimValue(values.getAllValues()[i]);
                if (value.isNotEmpty())
                    return value;
            }
        }
    }

    return {};
}

TrackMetadata fallbackForFile(const juce::File& file)
{
    TrackMetadata metadata;
    metadata.file = file;
    metadata.title = file.getFileNameWithoutExtension();
    metadata.artist = "Unknown Artist";
    metadata.album = "Local Files";
    return metadata;
}

juce::String sidecarLyricsForFile(const juce::File& file)
{
    if (file == juce::File{})
        return {};

    const auto sidecar = file.withFileExtension("lrc");
    if (!sidecar.existsAsFile() || sidecar.getSize() > 1024 * 1024)
        return {};

    return sidecar.loadFileAsString().trim();
}

namespace
{
bool parseTimestamp(const juce::String& value, double& seconds)
{
    const auto separator = value.indexOfChar(':');
    if (separator <= 0)
        return false;

    const auto minutes = value.substring(0, separator).trim();
    const auto remainder = value.substring(separator + 1).trim();
    if (minutes.isEmpty() || !minutes.containsOnly("0123456789") || remainder.isEmpty())
        return false;

    const auto decimalSeparator = remainder.indexOfChar('.');
    const auto wholeSeconds = decimalSeparator >= 0
                            ? remainder.substring(0, decimalSeparator)
                            : remainder;
    const auto fractionalSeconds = decimalSeparator >= 0
                                 ? remainder.substring(decimalSeparator + 1)
                                 : juce::String{};
    if (wholeSeconds.isEmpty()
        || !wholeSeconds.containsOnly("0123456789")
        || (decimalSeparator >= 0
            && (fractionalSeconds.isEmpty() || !fractionalSeconds.containsOnly("0123456789"))))
    {
        return false;
    }

    const auto parsedMinutes = minutes.getIntValue();
    const auto parsedSeconds = remainder.getDoubleValue();
    if (parsedMinutes < 0 || !std::isfinite(parsedSeconds) || parsedSeconds < 0.0
        || parsedSeconds >= 60.0)
    {
        return false;
    }

    seconds = static_cast<double>(parsedMinutes) * 60.0 + parsedSeconds;
    return true;
}
}

std::vector<LyricsLine> parseLyrics(const juce::String& lyrics)
{
    std::vector<LyricsLine> result;
    const auto lines = juce::StringArray::fromLines(lyrics);

    for (const auto& line : lines)
    {
        int cursor = 0;
        std::vector<double> timestamps;
        while (cursor < line.length() && line[cursor] == '[')
        {
            const auto end = line.indexOfChar(cursor + 1, ']');
            if (end < 0)
                break;

            double timestamp = 0.0;
            if (!parseTimestamp(line.substring(cursor + 1, end), timestamp))
                break;

            timestamps.push_back(timestamp);
            cursor = end + 1;
        }

        if (timestamps.empty())
            continue;

        const auto text = line.substring(cursor).trim();
        if (text.isEmpty())
            continue;

        for (const auto timestamp : timestamps)
            result.push_back({ timestamp, text });
    }

    std::stable_sort(result.begin(), result.end(), [](const auto& first, const auto& second)
    {
        return first.timeSeconds < second.timeSeconds;
    });
    return result;
}
}
