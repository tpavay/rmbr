import UIKit

/// The app's whole haptic vocabulary.
///
/// The rule these follow: a haptic confirms something the person did, or a threshold
/// they crossed. Nothing fires when data merely arrives - a place name landing from the
/// network is not something rmbr did, and saying so with the Taptic engine would be the
/// motion-layer version of overstating.
///
/// The generators are held rather than built per impact, and each one re-arms itself
/// after it fires. A cold engine answers late, and the film advance - one impact per
/// frame, as fast as a thumb can swipe - is exactly where a late impact is felt as a
/// missing one.
@MainActor
enum Haptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)

    /// Warms the engine for a surface about to lean on it. Prepares nothing else: a
    /// generator kept ready costs power for as long as it is.
    static func prepare() {
        rigidGenerator.prepare()
    }

    /// A new month takes the rule; a page turns; a year is crossed.
    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// A screen changes state under the person's finger.
    static func soft() {
        softGenerator.impactOccurred()
        softGenerator.prepare()
    }

    /// A photograph lands. The densest feedback in the app, and deliberate: the film
    /// advance fires one per frame because that is the shutter feeling it is named for.
    static func rigid() {
        rigidGenerator.impactOccurred()
        rigidGenerator.prepare()
    }
}
