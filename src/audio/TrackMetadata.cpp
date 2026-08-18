#include "TrackMetadata.h"

#include <algorithm>

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
}
