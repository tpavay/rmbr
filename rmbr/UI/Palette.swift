import SwiftUI

/// Velvet Ember Dusk, the settled design system.
///
/// Two typefaces and four values, and no others. Ember is never decoration: it marks
/// the live edge of the day or the interactive thing, and two competing ember elements
/// on one screen means one of them is wrong.
///
/// Playfair Display is the editorial voice. Milestone 1 does not bundle the font file,
/// so the system serif stands in for it at the same sizes and roles - the hierarchy is
/// the thing being judged here, not the typeface.
enum Palette {
    static let deepInk = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255)
    static let moonlightWhite = Color(red: 0xF8 / 255, green: 0xF9 / 255, blue: 0xFA / 255)
    static let dustyZinc = Color(red: 0x71 / 255, green: 0x71 / 255, blue: 0x7A / 255)
    static let emberGlow = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
    /// Smoked Glass is a style rather than a hex: white at a low opacity over blur.
    static let smokedGlass = Color.white.opacity(0.07)
}

extension Font {
    /// The editorial voice. Never below 13 points, where it stops being elegant.
    static func editorial(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: max(13, size), weight: weight, design: .serif)
    }

    /// The utility voice: times, counts, units, labels. Never editorialises.
    static func utility(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension View {
    /// A small uppercase section label in the utility voice.
    func sectionLabelStyle() -> some View {
        self
            .font(.utility(11, weight: .semibold))
            .textCase(.uppercase)
            .kerning(1.4)
            .foregroundStyle(Palette.dustyZinc)
    }
}
