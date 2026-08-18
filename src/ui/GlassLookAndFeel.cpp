#include "GlassLookAndFeel.h"

namespace
{
enum class IconKind
{
    none,
    add,
    play,
    pause,
    stop,
    previous,
    next,
    loop
};

IconKind iconForButton(const juce::TextButton& button)
{
    const auto id = button.getComponentID();

    if (id == "icon-add")             return IconKind::add;
    if (id == "icon-featured-play")   return IconKind::play;
    if (id == "icon-play")            return button.getButtonText() == "Pause" ? IconKind::pause : IconKind::play;
    if (id == "icon-stop")            return IconKind::stop;
    if (id == "icon-previous")        return IconKind::previous;
    if (id == "icon-next")            return IconKind::next;
    if (id == "icon-loop")            return IconKind::loop;

    return IconKind::none;
}

void drawIcon(juce::Graphics& g, juce::Rectangle<float> bounds, IconKind kind, juce::Colour colour)
{
    const auto area = bounds.reduced(9.0f);
    const auto centre = area.getCentre();
    const float stroke = 1.8f;
    g.setColour(colour);

    switch (kind)
    {
        case IconKind::add:
            g.drawLine(centre.x - 6.0f, centre.y, centre.x + 6.0f, centre.y, stroke);
            g.drawLine(centre.x, centre.y - 6.0f, centre.x, centre.y + 6.0f, stroke);
            break;

        case IconKind::play:
        {
            juce::Path path;
            path.addTriangle(area.getX() + 3.0f, area.getY() + 1.0f,
                             area.getRight() - 2.0f, centre.y,
                             area.getX() + 3.0f, area.getBottom() - 1.0f);
            g.fillPath(path);
            break;
        }

        case IconKind::pause:
            g.fillRoundedRectangle(centre.x - 6.0f, centre.y - 7.0f, 4.0f, 14.0f, 1.0f);
            g.fillRoundedRectangle(centre.x + 2.0f, centre.y - 7.0f, 4.0f, 14.0f, 1.0f);
            break;

        case IconKind::stop:
            g.fillRoundedRectangle(centre.x - 6.0f, centre.y - 6.0f, 12.0f, 12.0f, 2.0f);
            break;

        case IconKind::previous:
        case IconKind::next:
        {
            const bool pointsLeft = kind == IconKind::previous;
            const float edge = pointsLeft ? area.getX() + 3.0f : area.getRight() - 3.0f;
            const float tip = pointsLeft ? area.getX() + 8.0f : area.getRight() - 8.0f;
            juce::Path triangle;
            if (pointsLeft)
                triangle.addTriangle(tip, area.getY() + 1.0f, edge, centre.y, tip, area.getBottom() - 1.0f);
            else
                triangle.addTriangle(tip, centre.y, edge, area.getY() + 1.0f, edge, area.getBottom() - 1.0f);
            g.fillPath(triangle);

            const float lineX = pointsLeft ? area.getX() + 1.0f : area.getRight() - 1.0f;
            g.drawLine(lineX, area.getY() + 1.0f, lineX, area.getBottom() - 1.0f, stroke);
            break;
        }

        case IconKind::loop:
        {
            const auto arc = area.reduced(2.0f);
            const auto pi = juce::MathConstants<float>::pi;
            const auto strokeType = juce::PathStrokeType(stroke,
                                                         juce::PathStrokeType::curved,
                                                         juce::PathStrokeType::rounded);

            juce::Path topArc;
            topArc.addCentredArc(arc.getCentreX(), arc.getCentreY(),
                                 arc.getWidth() * 0.5f, arc.getHeight() * 0.5f,
                                 0.0f, pi * 0.15f, pi * 1.05f, true);
            g.strokePath(topArc, strokeType);

            juce::Path bottomArc;
            bottomArc.addCentredArc(arc.getCentreX(), arc.getCentreY(),
                                    arc.getWidth() * 0.5f, arc.getHeight() * 0.5f,
                                    0.0f, pi * 1.15f, pi * 2.05f, true);
            g.strokePath(bottomArc, strokeType);

            juce::Path topArrow;
            topArrow.addTriangle(arc.getRight() - 1.0f, arc.getY() + 2.0f,
                                 arc.getRight() - 7.0f, arc.getY() + 1.0f,
                                 arc.getRight() - 2.0f, arc.getY() + 7.0f);
            g.fillPath(topArrow);

            juce::Path bottomArrow;
            bottomArrow.addTriangle(arc.getX() + 1.0f, arc.getBottom() - 2.0f,
                                    arc.getX() + 7.0f, arc.getBottom() - 1.0f,
                                    arc.getX() + 2.0f, arc.getBottom() - 7.0f);
            g.fillPath(bottomArrow);
            break;
        }

        case IconKind::none:
            break;
    }
}
}

GlassLookAndFeel::GlassLookAndFeel()
{
    setColour(juce::ResizableWindow::backgroundColourId, juce::Colours::transparentBlack);
    setColour(juce::TextButton::buttonColourId, glassFill());
    setColour(juce::TextButton::textColourOffId, inkPrimary());
    setColour(juce::TextButton::textColourOnId, inkPrimary());
    setColour(juce::Slider::thumbColourId, accent());
    setColour(juce::Slider::trackColourId, accent());
    setColour(juce::Slider::backgroundColourId, juce::Colour(0xffdfe5ef));
    setColour(juce::Label::textColourId, inkPrimary());
}

void GlassLookAndFeel::drawButtonBackground(juce::Graphics& g,
                                            juce::Button& button,
                                            const juce::Colour&,
                                            bool shouldDrawButtonAsHighlighted,
                                            bool shouldDrawButtonAsDown)
{
    auto bounds = button.getLocalBounds().toFloat().reduced(1.0f);
    const float radius = 9.0f;
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
    const auto kind = iconForButton(button);
    if (kind == IconKind::none)
    {
        const auto id = button.getComponentID();
        const auto colour = id == "primary" ? juce::Colours::white
                                             : inkPrimary();
        g.setColour(button.isEnabled() ? colour : colour.withAlpha(0.45f));
        g.setFont(getTextButtonFont(button, button.getHeight()));
        g.drawFittedText(button.getButtonText(),
                         button.getLocalBounds().reduced(8, 0),
                         juce::Justification::centred,
                         1);
        return;
    }

    const bool isPrimary = button.getComponentID() == "icon-featured-play"
                        || button.getComponentID() == "icon-play";
    const auto colour = isPrimary ? juce::Colours::white : inkPrimary();
    drawIcon(g, button.getLocalBounds().toFloat(), kind, colour);
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
