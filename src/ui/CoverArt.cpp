#include "CoverArt.h"

namespace CoverArt
{
namespace
{
juce::Colour placeholderColour(const juce::String& key)
{
    const auto hash = static_cast<uint32_t>(key.hashCode());
    const auto hue = static_cast<float>(hash % 1000u) / 1000.0f;
    return juce::Colour::fromHSV(hue, 0.26f, 0.84f, 1.0f);
}
}

void draw(juce::Graphics& g,
          juce::Rectangle<float> bounds,
          const juce::Image* artwork,
          const juce::String& key,
          const juce::String& title,
          float cornerRadius)
{
    if (bounds.isEmpty())
        return;

    juce::Path clip;
    clip.addRoundedRectangle(bounds, cornerRadius);
    g.saveState();
    g.reduceClipRegion(clip);

    if (artwork != nullptr && artwork->isValid())
    {
        // drawImage() uses the current brush opacity. Callers often draw a shadow or a
        // translucent highlight first, which would otherwise wash the cover out.
        g.setOpacity(1.0f);
        g.setImageResamplingQuality(juce::Graphics::highResamplingQuality);
        g.drawImage(*artwork,
                    bounds,
                    juce::RectanglePlacement::centred | juce::RectanglePlacement::fillDestination);
    }
    else
    {
        const auto colour = placeholderColour(key);
        g.setGradientFill(juce::ColourGradient(colour.brighter(0.12f),
                                                bounds.getTopLeft(),
                                                colour.darker(0.10f),
                                                bounds.getBottomRight(),
                                                false));
        g.fillRect(bounds);

        const auto initial = title.trim().substring(0, 1).toUpperCase();
        if (initial.isNotEmpty())
        {
            g.setColour(juce::Colours::white.withAlpha(0.85f));
            g.setFont(juce::Font(juce::FontOptions(bounds.getHeight() * 0.38f)).boldened());
            g.drawText(initial, bounds, juce::Justification::centred, false);
        }
    }

    g.restoreState();

    // Hairline edge keeps light covers from dissolving into the background.
    g.setColour(juce::Colours::black.withAlpha(0.08f));
    g.drawRoundedRectangle(bounds.reduced(0.25f), cornerRadius, 0.5f);
}
}
