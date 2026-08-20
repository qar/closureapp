#pragma once

#include <JuceHeader.h>

namespace AudioFileFormats
{
inline bool isSupported(const juce::File& file)
{
    const auto extension = file.getFileExtension().toLowerCase();
    return extension == ".mp3" || extension == ".flac" || extension == ".wav"
        || extension == ".aiff" || extension == ".aif" || extension == ".m4a"
        || extension == ".alac" || extension == ".ogg";
}

inline juce::String wildcardPattern()
{
    return "*.mp3;*.flac;*.wav;*.aiff;*.aif;*.m4a;*.alac;*.ogg";
}
}
