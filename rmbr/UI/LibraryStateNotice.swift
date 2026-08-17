import SwiftUI

/// What a screen says when the library it describes is not available to it.
///
/// A pushed day or month outlives the reconstruction it was opened against: the grant can
/// be narrowed or refused underneath it, and a walk can fail. Rendering the screen's own
/// empty state would claim the day or the month held nothing, and saying rmbr is reading
/// the library would promise a return that a refusal is never going to deliver. Each
/// phase says what is actually true of it (RQ-043, RQ-053).
struct LibraryStateNotice: View {
    let heading: String
    /// What the person is waiting for, in the sentence: "this day", "this month".
    let subject: String
    let phase: LibraryPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(.editorial(32))
                .foregroundStyle(Palette.moonlightWhite)
                .accessibilityAddTraits(.isHeader)
            Text(sentence)
                .font(.utility(15))
                .foregroundStyle(Palette.dustyZinc)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 52)
    }

    private var sentence: String {
        switch phase {
        case .checkingPermission, .indexing, .ready:
            "rmbr is reading your library. This \(subject) comes back when it has finished."
        case .awaitingPermission:
            "rmbr has not been allowed to see your photographs yet, so there is nothing"
                + " to rebuild this \(subject) from."
        case .permissionRefused:
            "rmbr cannot see your photographs. Photo access can be changed in Settings."
        case .failed(let message):
            "Reconstruction stopped, so rmbr cannot show this \(subject). \(message)"
        }
    }
}
