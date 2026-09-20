import Combine
import Foundation

/// A single size authority shared by SwiftUI and the native popover.
@MainActor
public final class MenuPanelSizing: ObservableObject {
    @Published public private(set) var height: CGFloat = 577
    public private(set) var maximumHeight: CGFloat = 760
    private var measurements: [String: CGFloat] = [:]
    private var page = "quota"
    private var headerHeight: CGFloat = 57

    public init() {}

    public func measure(contentHeight: CGFloat, page: String, headerHeight: CGFloat = 57) {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        measurements[page] = ceil(contentHeight)
        self.headerHeight = headerHeight
        if self.page == page { update() }
    }

    public func select(page: String) { self.page = page; update() }

    public func setMaximumHeight(_ height: CGFloat) {
        guard height.isFinite, height >= 80 else { return }
        maximumHeight = height; update()
    }

    private func update() {
        let next = min(maximumHeight, ceil((measurements[page] ?? 520) + headerHeight))
        if abs(height - next) >= 1 { height = next }
    }
}
