#pragma once

#include <JuceHeader.h>

/** Soft glass / late-2000s AirPlay-era aesthetic. */
class GlassLookAndFeel final : public juce::LookAndFeel_V4
{
public:
    GlassLookAndFeel();

    void drawButtonBackground(juce::Graphics& g,
                              juce::Button& button,
                              const juce::Colour& backgroundColour,
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

    static juce::Colour glassFill() { return juce::Colour(0x55ffffff); }
    static juce::Colour glassStroke() { return juce::Colour(0x66ffffff); }
    static juce::Colour inkPrimary() { return juce::Colour(0xff1a1a22); }
    static juce::Colour inkMuted() { return juce::Colour(0xaa2a2a35); }
    static juce::Colour accent() { return juce::Colour(0xff5b8def); }
};
