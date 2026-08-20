#include "GlassLookAndFeel.h"

GlassLookAndFeel::GlassLookAndFeel()
{
    setColour(juce::ResizableWindow::backgroundColourId, juce::Colours::transparentBlack);
    setColour(juce::TextButton::buttonColourId, glassFill());
    setColour(juce::TextButton::textColourOffId, inkPrimary());
    setColour(juce::TextButton::textColourOnId, inkPrimary());
    setColour(juce::Slider::thumbColourId, accent());
    setColour(juce::Slider::trackColourId, accent());
    setColour(juce::Slider::backgroundColourId, glassStroke());
    setColour(juce::Label::textColourId, inkPrimary());
}

void GlassLookAndFeel::drawButtonBackground(juce::Graphics& g,
                                            juce::Button& button,
                                            const juce::Colour&,
                                            bool shouldDrawButtonAsHighlighted,
                                            bool shouldDrawButtonAsDown)
{
    auto bounds = button.getLocalBounds().toFloat().reduced(1.0f);
    const float radius = 6.0f;
    const auto id = button.getComponentID();
    const bool isPrimary = id == "primary" || id == "icon-featured-play" || id == "icon-play";
    const bool isQuiet = id == "quiet";
    const bool isOption = id == "option";
    const bool isToggled = button.getToggleState();

    auto fill = isPrimary ? accent()
                          : (isQuiet ? juce::Colours::transparentBlack
                                     : (isOption && isToggled
                                            ? accent().withAlpha(0.12f)
                                            : glassFill()));
    if (!button.isEnabled())
        fill = isQuiet ? juce::Colours::transparentBlack : fill.withAlpha(0.45f);

    if (shouldDrawButtonAsDown)
        fill = fill.darker(0.08f);
    else if (shouldDrawButtonAsHighlighted)
        fill = isQuiet ? glassFill() : fill.brighter(0.05f);

    g.setColour(fill);
    g.fillRoundedRectangle(bounds, radius);

    g.setColour(isPrimary ? juce::Colours::white.withAlpha(0.32f)
                          : (isQuiet ? juce::Colours::transparentBlack : glassStroke()));
    g.drawRoundedRectangle(bounds, radius, 1.0f);
}

void GlassLookAndFeel::drawButtonText(juce::Graphics& g,
                                      juce::TextButton& button,
                                      bool /*shouldDrawButtonAsHighlighted*/,
                                      bool /*shouldDrawButtonAsDown*/)
{
    const auto id = button.getComponentID();
    const auto colour = id == "primary" ? juce::Colours::white : inkPrimary();
    g.setColour(button.isEnabled() ? colour : colour.withAlpha(0.45f));
    g.setFont(getTextButtonFont(button, button.getHeight()));
    g.drawFittedText(button.getButtonText(),
                     button.getLocalBounds().reduced(8, 0),
                     juce::Justification::centred,
                     1);
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

        const float thumb = 7.0f;
        juce::Point<float> centre(sliderPos, line.getCentreY());
        g.setColour(slider.isEnabled()
                        ? findColour(juce::Slider::thumbColourId)
                        : findColour(juce::Slider::thumbColourId).withAlpha(0.4f));
        g.fillEllipse(centre.x - thumb, centre.y - thumb, thumb * 2.0f, thumb * 2.0f);
        g.setColour(juce::Colours::black.withAlpha(0.14f));
        g.drawEllipse(centre.x - thumb, centre.y - thumb, thumb * 2.0f, thumb * 2.0f, 1.0f);
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
