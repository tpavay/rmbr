import SwiftUI

/// What Life says when it has permission and nothing behind it.
///
/// The library was read; it is simply empty. There is no spinner, because nothing is
/// coming, and no invitation to go and take a photograph, because rmbr states what it
/// has rather than asking anything of the person holding the phone.
struct EmptyLibraryNotice: View {
    let access: PhotoLibraryAccess
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text(heading)
                .font(.editorial(27))
                .foregroundStyle(Palette.moonlightWhite)
                .multilineTextAlignment(.center)
            Text(sentence)
                .font(.utility(13.5))
                .foregroundStyle(Palette.dustyZinc)
                .multilineTextAlignment(.center)
            // The only empty state that earns a button, because iOS gives rmbr a real
            // one to call. Nothing else here has an action worth offering.
            if access == .limited {
                Button("Choose photographs") {
                    Haptics.soft()
                    onChoose()
                }
                .font(.utility(14, weight: .semibold))
                .foregroundStyle(Palette.deepInk)
                .padding(.horizontal, 21)
                .padding(.vertical, 11)
                .background(Palette.emberGlow, in: Capsule())
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 42)
    }

    private var heading: String {
        access == .limited
            ? "rmbr can see only the photographs you chose."
            : "No photographs on this phone yet."
    }

    private var sentence: String {
        access == .limited
            ? "None were chosen, so there is nothing to rebuild a day from."
            : "rmbr rebuilds days from what the camera roll already holds."
    }
}
