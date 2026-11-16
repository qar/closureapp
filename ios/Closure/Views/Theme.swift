import SwiftUI
import UIKit

/// Design tokens from the "A · Liner Notes" direction (Figma: MM-Test › Closure iOS › 7 · Tokens).
enum Theme {
    static let paper = Color(hex: 0xF2EFE8)
    static let paper2 = Color(hex: 0xE9E5DC)
    static let ink = Color(hex: 0x171512)
    static let muted = Color(hex: 0x6F6A61)
    /// Used only to mark what is playing now.
    static let accent = Color(hex: 0xD4512A)
    static let hairline = ink.opacity(0.14)

    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom("InstrumentSerif-Regular", size: size, relativeTo: style)
    }

    static func mono(_ size: CGFloat, medium: Bool = true, relativeTo style: Font.TextStyle = .caption2) -> Font {
        .custom(medium ? "ClosureMono-Medium" : "ClosureMono-Regular", size: size, relativeTo: style)
    }

    static let horizontalMargin: CGFloat = 24
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Small uppercase monospaced label ("FLAC 24/96", "ALBUMS").
struct MetaText: View {
    let text: String
    var size: CGFloat = 10.5
    var color: Color = Theme.muted
    var tracking: CGFloat = 1.4

    init(_ text: String, size: CGFloat = 10.5, color: Color = Theme.muted, tracking: CGFloat = 1.4) {
        self.text = text
        self.size = size
        self.color = color
        self.tracking = tracking
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(size))
            .tracking(tracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.paper)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.ink.opacity(0.9), lineWidth: 1.2))
    }
}

/// Icon-only button with a 44 pt hit area.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 20
    var weight: Font.Weight = .regular
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Keeps the edge swipe-back gesture when a screen draws its own back button.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
