#pragma once

#include <JuceHeader.h>

/** Lightweight frosted-glass controls for the desktop player layout. */
class GlassLookAndFeel final : public juce::LookAndFeel_V4
{
public:
    GlassLookAndFeel();

    void drawButtonBackground(juce::Graphics& g,
                              juce::Button& button,
                              const juce::Colour& backgroundColour,
                              bool shouldDrawButtonAsHighlighted,
                              bool shouldDrawButtonAsDown) override;

    void drawButtonText(juce::Graphics& g,
                        juce::TextButton& button,
                        bool shouldDrawButtonAsHighlighted,
                        bool shouldDrawButtonAsDown) override;

    void drawLinearSlider(juce::Graphics& g,
                          int x, int y, int width, int height,
                          float sliderPos,
                          float minSliderPos,
                          float maxSliderPos,
                          juce::Slider::SliderStyle style,
                          juce::Slider& slider) override;

    juce::Font getTextButtonFont(juce::TextButton&, int buttonHeight) override;
    juce::Font getLabelFont(juce::Label&) override;

    static juce::Colour glassFill() { return juce::Colour(0xffffffff); }
    static juce::Colour glassStroke() { return juce::Colour(0xffd9ded8); }
    static juce::Colour inkPrimary() { return juce::Colour(0xff182019); }
    static juce::Colour inkMuted() { return juce::Colour(0xff70776f); }
    static juce::Colour accent() { return juce::Colour(0xff19241d); }
};
