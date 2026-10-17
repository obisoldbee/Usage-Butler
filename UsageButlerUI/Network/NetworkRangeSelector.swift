import SwiftUI
import UsageButlerDomain

/// Both live and persisted trends keep the same targets and selected state.
struct NetworkRangeSelector: View {
    @Binding var range: NetworkTrendRange
    var body: some View {
        HStack(spacing: 3) {
            ForEach(NetworkTrendRange.allCases) { option in
                Button { range = option } label: {
                    Text(option.title).font(.system(size: 11))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(range == option ? Color.white : Color.primary)
                        .background(range == option ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("network.range.\(option.rawValue)")
                    .accessibilityAddTraits(range == option ? .isSelected : [])
            }
        }
    }
}
