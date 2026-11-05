#pragma once

#include <JuceHeader.h>

/** Shared album/track cover drawing, so every cover in the app looks the same. */
namespace CoverArt
{
/** Draw `artwork` (cropped to fill) inside rounded `bounds`. When there is no artwork,
    draw a quiet tinted placeholder keyed by `key`, with the initial of `title`. */
void draw(juce::Graphics& g,
          juce::Rectangle<float> bounds,
          const juce::Image* artwork,
          const juce::String& key,
          const juce::String& title,
          float cornerRadius);
}
