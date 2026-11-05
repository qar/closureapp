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
    setColour(juce::ScrollBar::thumbColourId, inkPrimary());
    setColour(juce::ScrollBar::trackColourId, juce::Colours::transparentBlack);
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

    if (id == "chip")
    {
        // Quiet toggle chip: no border; a soft fill marks the on state.
        auto chip = button.getLocalBounds().toFloat();
        auto alpha = isToggled ? 0.09f : 0.0f;
        if (shouldDrawButtonAsDown)
            alpha += 0.06f;
        else if (shouldDrawButtonAsHighlighted)
            alpha += 0.04f;

        g.setColour(accent().withAlpha(alpha));
        g.fillRoundedRectangle(chip, 7.0f);
        return;
    }

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
    const auto colour = id == "primary" ? juce::Colours::white
                      : (id == "chip" && !button.getToggleState() ? inkMuted() : inkPrimary());
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

        g.setColour(inkPrimary().withAlpha(0.10f));
        g.fillRoundedRectangle(line, trackH * 0.5f);

        auto filled = line.withWidth(juce::jmax(0.0f, sliderPos - line.getX()));
        g.setColour(slider.isEnabled() ? inkPrimary().withAlpha(0.78f) : inkMuted().withAlpha(0.4f));
        g.fillRoundedRectangle(filled, trackH * 0.5f);

        // macOS-style knob: small white disc, soft shadow, hairline edge.
        const float thumb = slider.isMouseOverOrDragging() ? 7.0f : 6.0f;
        const juce::Point<float> centre(sliderPos, line.getCentreY());
        const auto knob = juce::Rectangle<float>(thumb * 2.0f, thumb * 2.0f).withCentre(centre);
        juce::Path knobPath;
        knobPath.addEllipse(knob);
        juce::DropShadow(juce::Colours::black.withAlpha(0.22f), 4, { 0, 1 }).drawForPath(g, knobPath);
        g.setColour(juce::Colours::white);
        g.fillPath(knobPath);
        g.setColour(juce::Colours::black.withAlpha(0.12f));
        g.strokePath(knobPath, juce::PathStrokeType(0.5f));
    }
    else
    {
        juce::LookAndFeel_V4::drawLinearSlider(g, x, y, width, height, sliderPos,
                                               0, 0, slider.getSliderStyle(), slider);
    }
}

void GlassLookAndFeel::drawTabbedButtonBarBackground(juce::TabbedButtonBar& bar,
                                                      juce::Graphics& g)
{
    // Segmented control track: one quiet rounded well that holds every tab.
    const auto track = bar.getLocalBounds().toFloat();
    g.setColour(inkPrimary().withAlpha(0.07f));
    g.fillRoundedRectangle(track, 8.0f);
}

void GlassLookAndFeel::drawTabButton(juce::TabBarButton& button,
                                     juce::Graphics& g,
                                     bool isMouseOver,
                                     bool /*isMouseDown*/)
{
    const auto isActive = button.isFrontTab();
    auto segment = button.getLocalBounds().toFloat().reduced(2.0f);

    if (isActive)
    {
        juce::Path pill;
        pill.addRoundedRectangle(segment, 6.0f);
        juce::DropShadow(juce::Colours::black.withAlpha(0.12f), 4, { 0, 1 }).drawForPath(g, pill);
        g.setColour(juce::Colours::white);
        g.fillPath(pill);
    }

    g.setColour(isActive || isMouseOver ? inkPrimary() : inkMuted());
    g.setFont(getTabButtonFont(button, segment.getHeight()));
    g.drawText(button.getButtonText(), segment, juce::Justification::centred, false);
}

void GlassLookAndFeel::drawTabAreaBehindFrontButton(juce::TabbedButtonBar&,
                                                     juce::Graphics&,
                                                     int,
                                                     int)
{
}

int GlassLookAndFeel::getTabButtonBestWidth(juce::TabBarButton& button, int)
{
    // Equal-width segments that fill the bar.
    auto& bar = button.getTabbedButtonBar();
    return bar.getWidth() / juce::jmax(1, bar.getNumTabs());
}

int GlassLookAndFeel::getTabButtonOverlap(int)
{
    return 0;
}

int GlassLookAndFeel::getTabButtonSpaceAroundImage()
{
    return 0;
}

juce::Font GlassLookAndFeel::getTabButtonFont(juce::TabBarButton& button, float)
{
    const auto font = juce::Font(juce::FontOptions(13.0f));
    return button.isFrontTab() ? font.boldened() : font;
}

int GlassLookAndFeel::getDefaultScrollbarWidth()
{
    return 10;
}

void GlassLookAndFeel::drawScrollbar(juce::Graphics& g,
                                     juce::ScrollBar&,
                                     int x, int y, int width, int height,
                                     bool isScrollbarVertical,
                                     int thumbStartPosition,
                                     int thumbSize,
                                     bool isMouseOver,
                                     bool isMouseDown)
{
    // Overlay-style scroller: no track, a thin rounded thumb that thickens on hover.
    if (thumbSize <= 0)
        return;

    const auto thickness = isMouseOver || isMouseDown ? 7.0f : 5.0f;
    juce::Rectangle<float> thumb;

    if (isScrollbarVertical)
        thumb = { (float) (x + width) - thickness - 2.0f, (float) thumbStartPosition + 2.0f,
                  thickness, (float) thumbSize - 4.0f };
    else
        thumb = { (float) thumbStartPosition + 2.0f, (float) (y + height) - thickness - 2.0f,
                  (float) thumbSize - 4.0f, thickness };

    g.setColour(inkPrimary().withAlpha(isMouseDown ? 0.45f : (isMouseOver ? 0.32f : 0.20f)));
    g.fillRoundedRectangle(thumb, thickness * 0.5f);
}

void GlassLookAndFeel::drawDrawableButton(juce::Graphics& g,
                                          juce::DrawableButton& button,
                                          bool shouldDrawButtonAsHighlighted,
                                          bool shouldDrawButtonAsDown)
{
    const auto id = button.getComponentID();
    const auto bounds = button.getLocalBounds().toFloat();
    const auto enabledAlpha = button.isEnabled() ? 1.0f : 0.35f;

    if (id == "transport-play")
    {
        // Primary control: solid ink disc with a white glyph.
        auto colour = inkPrimary();
        if (shouldDrawButtonAsDown)
            colour = colour.brighter(0.25f);
        else if (shouldDrawButtonAsHighlighted)
            colour = colour.brighter(0.15f);

        const auto size = juce::jmin(bounds.getWidth(), bounds.getHeight());
        g.setColour(colour.withMultipliedAlpha(enabledAlpha));
        g.fillEllipse(bounds.withSizeKeepingCentre(size, size));
        return;
    }

    if (id == "option")
    {
        // Same language as the "chip" text toggle: fill marks the on state.
        auto alpha = button.getToggleState() ? 0.09f : 0.0f;
        if (shouldDrawButtonAsDown)
            alpha += 0.06f;
        else if (shouldDrawButtonAsHighlighted)
            alpha += 0.04f;

        g.setColour(accent().withAlpha(alpha * enabledAlpha));
        g.fillRoundedRectangle(bounds, 7.0f);
        return;
    }

    if (button.isEnabled() && (shouldDrawButtonAsHighlighted || shouldDrawButtonAsDown))
    {
        // Secondary transport buttons: a faint round hover well.
        const auto size = juce::jmin(bounds.getWidth(), bounds.getHeight());
        g.setColour(inkPrimary().withAlpha(shouldDrawButtonAsDown ? 0.10f : 0.06f));
        g.fillEllipse(bounds.withSizeKeepingCentre(size, size));
    }
}

juce::Font GlassLookAndFeel::getTextButtonFont(juce::TextButton& button, int buttonHeight)
{
    if (button.getComponentID() == "chip")
        return juce::Font(juce::FontOptions(13.0f));

    return juce::Font(juce::FontOptions((float) juce::jmin(13, buttonHeight / 2)));
}

juce::Font GlassLookAndFeel::getLabelFont(juce::Label& label)
{
    // Respect each label's own font; a fixed font here flattened every text hierarchy.
    return label.getFont();
}
