import SwiftUI

/// The credit Geoapify's terms require wherever a stored place label is shown.
///
/// One view rather than the same sentence written into each screen, so a surface that
/// displays a stored label cannot display it uncredited. The lines come from the days
/// themselves through `Day.placeAttributions`, which is what keeps the obligation
/// travelling with the data rather than with whoever remembers it.
struct PlaceAttributionFooter: View {
    let attributions: [String]

    var body: some View {
        if !attributions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(attributions, id: \.self) { line in
                    Text("Place names \(line), via Geoapify")
                        .font(.utility(11))
                        .foregroundStyle(Palette.dustyZinc)
                }
            }
        }
    }
}
