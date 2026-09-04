import SwiftUI
import UsageButlerCore
import UsageButlerDomain

public struct MenuPanelRootView: View {
    @ObservedObject private var model: MenuPanelViewModel
    private let activityMonitorState: ActivityMonitorActionState
    private let onOpenActivityMonitor: () -> Void
    private let onOpenSettingsFallback: () -> Void

    public init(
        model: MenuPanelViewModel,
        activityMonitorState: ActivityMonitorActionState,
        onOpenActivityMonitor: @escaping () -> Void,
        onOpenSettingsFallback: @escaping () -> Void
    ) {
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
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 540, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.panelPresented()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("额度管家")
                    .font(.headline)
                Text("Usage-Butler")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Picker("页面", selection: $model.selectedPage) {
                ForEach(MenuPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            Spacer(minLength: 8)

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
            .buttonStyle(.borderless)
            .disabled(model.isManualRefreshInFlight)
            .help("刷新")
            .accessibilityLabel("刷新")

            settingsButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
