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

    void drawDrawableButton(juce::Graphics& g,
                            juce::DrawableButton& button,
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

    void drawTabbedButtonBarBackground(juce::TabbedButtonBar& bar,
                                       juce::Graphics& g) override;
    void drawTabButton(juce::TabBarButton& button,
                       juce::Graphics& g,
                       bool isMouseOver,
                       bool isMouseDown) override;
    void drawTabAreaBehindFrontButton(juce::TabbedButtonBar& bar,
                                      juce::Graphics& g,
                                      int width,
                                      int height) override;

    int getTabButtonBestWidth(juce::TabBarButton& button, int tabDepth) override;
    int getTabButtonOverlap(int tabDepth) override;
    int getTabButtonSpaceAroundImage() override;
    juce::Font getTabButtonFont(juce::TabBarButton&, float height) override;

    int getDefaultScrollbarWidth() override;
    void drawScrollbar(juce::Graphics& g,
                       juce::ScrollBar& scrollbar,
                       int x, int y, int width, int height,
                       bool isScrollbarVertical,
                       int thumbStartPosition,
                       int thumbSize,
                       bool isMouseOver,
                       bool isMouseDown) override;

    juce::Font getTextButtonFont(juce::TextButton&, int buttonHeight) override;
    juce::Font getLabelFont(juce::Label&) override;

    static juce::Colour glassFill() { return juce::Colour(0xffffffff); }
    static juce::Colour glassStroke() { return juce::Colour(0xffd9ded8); }
    static juce::Colour inkPrimary() { return juce::Colour(0xff182019); }
    static juce::Colour inkMuted() { return juce::Colour(0xff70776f); }
    static juce::Colour accent() { return juce::Colour(0xff19241d); }
};
