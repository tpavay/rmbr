import UIKit

/// The app's whole haptic vocabulary.
///
/// The rule these follow: a haptic confirms something the person did, or a threshold
/// they crossed. Nothing fires when data merely arrives - a place name landing from the
/// network is not something rmbr did, and saying so with the Taptic engine would be the
/// motion-layer version of overstating.
@MainActor
enum Haptics {
    /// A new month takes the rule; a page turns; a year is crossed.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A screen changes state under the person's finger.
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// A photograph lands. The densest feedback in the app, and deliberate: the film
    /// advance fires one per frame because that is the shutter feeling it is named for.
    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
}
