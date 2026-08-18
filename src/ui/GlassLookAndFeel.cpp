#include "GlassLookAndFeel.h"

GlassLookAndFeel::GlassLookAndFeel()
{
    setColour(juce::ResizableWindow::backgroundColourId, juce::Colours::transparentBlack);
    setColour(juce::TextButton::buttonColourId, glassFill());
    setColour(juce::TextButton::textColourOffId, inkPrimary());
    setColour(juce::TextButton::textColourOnId, inkPrimary());
    setColour(juce::Slider::thumbColourId, juce::Colours::white);
    setColour(juce::Slider::trackColourId, accent().withAlpha(0.85f));
    setColour(juce::Slider::backgroundColourId, juce::Colour(0x33ffffff));
    setColour(juce::Label::textColourId, inkPrimary());
}

void GlassLookAndFeel::drawButtonBackground(juce::Graphics& g,
                                            juce::Button& button,
                                            const juce::Colour&,
                                            bool shouldDrawButtonAsHighlighted,
                                            bool shouldDrawButtonAsDown)
{
    auto bounds = button.getLocalBounds().toFloat().reduced(1.0f);
    const float radius = bounds.getHeight() * 0.5f;

    auto fill = glassFill();
    if (shouldDrawButtonAsDown)
        fill = fill.brighter(0.15f);
    else if (shouldDrawButtonAsHighlighted)
        fill = fill.brighter(0.08f);

    g.setColour(fill);
    g.fillRoundedRectangle(bounds, radius);

    g.setColour(glassStroke());
    g.drawRoundedRectangle(bounds, radius, 1.0f);

    // Soft top highlight — glass lip
    juce::ColourGradient gloss(juce::Colours::white.withAlpha(0.35f),
                               bounds.getX(), bounds.getY(),
                               juce::Colours::transparentWhite,
                               bounds.getX(), bounds.getCentreY(), false);
    g.setGradientFill(gloss);
    g.fillRoundedRectangle(bounds.removeFromTop(bounds.getHeight() * 0.45f), radius);
}

void GlassLookAndFeel::drawLinearSlider(juce::Graphics& g,
                                        int x, int y, int width, int height,
                                        float sliderPos,
                                        float /*minSliderPos*/,
                                        float /*maxSliderPos*/,
                                        juce::Slider::SliderStyle,
                                        juce::Slider& slider)
{
    const bool isHorizontal = slider.isHorizontal();
    auto track = juce::Rectangle<float>((float) x, (float) y, (float) width, (float) height);

    if (isHorizontal)
    {
        const float trackH = 4.0f;
        auto line = track.withSizeKeepingCentre(track.getWidth(), trackH);

        g.setColour(findColour(juce::Slider::backgroundColourId));
        g.fillRoundedRectangle(line, trackH * 0.5f);

        auto filled = line.withWidth(juce::jmax(0.0f, sliderPos - line.getX()));
        juce::ColourGradient grad(accent().brighter(0.2f), filled.getX(), filled.getY(),
                                  accent().darker(0.1f), filled.getRight(), filled.getY(), false);
        g.setGradientFill(grad);
        g.fillRoundedRectangle(filled, trackH * 0.5f);

        const float thumbR = 7.0f;
        juce::Point<float> c(sliderPos, line.getCentreY());
        g.setColour(juce::Colours::white.withAlpha(0.95f));
        g.fillEllipse(c.x - thumbR, c.y - thumbR, thumbR * 2.0f, thumbR * 2.0f);
        g.setColour(juce::Colours::black.withAlpha(0.12f));
        g.drawEllipse(c.x - thumbR, c.y - thumbR, thumbR * 2.0f, thumbR * 2.0f, 1.0f);
    }
    else
    {
        juce::LookAndFeel_V4::drawLinearSlider(g, x, y, width, height, sliderPos,
                                               0, 0, slider.getSliderStyle(), slider);
    }
}

juce::Font GlassLookAndFeel::getTextButtonFont(juce::TextButton&, int buttonHeight)
{
    return juce::Font(juce::FontOptions((float) juce::jmin(15, buttonHeight / 2)));
}

juce::Font GlassLookAndFeel::getLabelFont(juce::Label&)
{
    return juce::Font(juce::FontOptions(14.0f));
}
