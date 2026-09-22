import SwiftUI
import UsageButlerCore
import UsageButlerDomain

public struct MenuPanelRootView: View {
    @ObservedObject private var sizing: MenuPanelSizing
    @ObservedObject private var model: MenuPanelViewModel
    private let activityMonitorState: ActivityMonitorActionState
    private let onOpenActivityMonitor: () -> Void
    private let onOpenSettingsFallback: () -> Void

    public init(
        model: MenuPanelViewModel,
        activityMonitorState: ActivityMonitorActionState,
        onOpenActivityMonitor: @escaping () -> Void,
        onOpenSettingsFallback: @escaping () -> Void,
        sizing: MenuPanelSizing = MenuPanelSizing()
    ) {
        self.sizing = sizing
        self.model = model
        self.activityMonitorState = activityMonitorState
        self.onOpenActivityMonitor = onOpenActivityMonitor
        self.onOpenSettingsFallback = onOpenSettingsFallback
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            #if USAGE_BUTLER_FIXTURES
            if model.isFixtureMode {
                fixtureNotice
            }
            #endif

            ScrollView {
                Group {
                    switch model.selectedPage {
                    case .quota:
                        QuotaOverviewView(
                            providers: model.snapshot.providers,
                            onLoginProvider: { providerID, request in
                                await model.loginProvider(
                                    providerID,
                                    request: request
                                )
                            }
                        )
                    case .memory:
                        MemoryOverviewView(
                            snapshot: model.snapshot.memory,
                            range: $model.memoryRange,
                            activityMonitorState: activityMonitorState,
                            onOpenActivityMonitor: onOpenActivityMonitor
                        )
                    case .network:
                        NetworkOverviewView(model: model, onOpenSettingsFallback: onOpenSettingsFallback)
                    }
                }
                .padding(16)
                .frame(width: 540)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PanelContentHeightKey.self,
                        value: [model.selectedPage.rawValue: geometry.size.height])
                })
            }
        }
        .frame(width: 540, height: sizing.height)
        .onPreferenceChange(PanelContentHeightKey.self) { measurements in
            for (page, height) in measurements {
                sizing.measure(contentHeight: height, page: page, headerHeight: measuredHeaderHeight)
            }
        }
        .onChange(of: model.selectedPage) { page in sizing.select(page: page.rawValue) }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            sizing.select(page: model.selectedPage.rawValue)
            model.panelPresented()
        }
    }

    private var measuredHeaderHeight: CGFloat {
        #if USAGE_BUTLER_FIXTURES
        if model.isFixtureMode { return 89 }
        #endif
        return 57
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 24) {
                ForEach(MenuPage.allCases) { page in
                    Button {
                        model.selectedPage = page
                    } label: {
                        Text(page.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(model.selectedPage == page ? .primary : .secondary)
                            .frame(minWidth: 44, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                if model.selectedPage == page {
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(height: 3)
                                        .padding(.bottom, 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selectedPage == page ? .isSelected : [])
                    .accessibilityIdentifier("menu.page.\(page.rawValue)")
                }
            }

            Spacer(minLength: 16)

            Button {
                model.requestManualRefresh()
            } label: {
                if model.isManualRefreshInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 28, height: 32)
            .buttonStyle(.borderless)
            .disabled(model.isManualRefreshInFlight)
            .help("刷新")
            .accessibilityLabel("刷新")

            settingsButton
                .frame(width: 28, height: 32)
        }
        .font(.system(size: 17))
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
            .accessibilityLabel("设置")
        } else {
            Button(action: onOpenSettingsFallback) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
            .accessibilityLabel("设置")
        }
    }

    #if USAGE_BUTLER_FIXTURES
    private var fixtureNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "hammer.fill")
                .foregroundStyle(.blue)
            Text("开发预览数据 · 尚未读取本机 CLI")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.055))
        .accessibilityElement(children: .combine)
    }
    #endif

}

private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
