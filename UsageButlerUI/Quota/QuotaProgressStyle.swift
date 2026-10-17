import SwiftUI

/// Draw the availability color directly; native linear indicators can retain
/// the system accent or inactive tint instead of the requested quota color.
struct QuotaProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            // Both directions retain the left end: used grows to the right;
            // remaining shrinks from the right as usage increases.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule().fill(color)
                    .frame(width: geometry.size.width * min(max(configuration.fractionCompleted ?? 0, 0), 1))
            }
        }
        .frame(height: 8)
    }
}
