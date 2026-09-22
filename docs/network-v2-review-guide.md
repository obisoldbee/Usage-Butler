# 网络 v2 独立 Review 入口

范围：macOS 原生0.3.0（3），对照公开父提交 `706824e4cc07914f4d8b55a89965cfd7c72ecb9e`。不要将旧归档里的未修复描述或设计包指令当成当前事实。

先读 `network-redesign-brief.md` 和 `network-v2-contract.md`，再核对源码与测试，区分 Observed / Inferred / Unknown。优先寻找可复现缺陷，给严重性、触发条件、文件行号、影响与最小修复建议。

1. `UsageButlerCore/Network/NetworkAggregator.swift`：各向baseline/epoch/reset/missing/gap；有意义的0和nil；UInt64溢出；源事件重放/乱序。
2. `NetworkRateHistoryBuffer.swift`、`NetworkChartProjection.swift`、`NetworkChartAxis.swift`：后台源历史、局部cadence、wall回拨、单调时钟、分段先于抽稀、峰值、独立刻度与共用游标。
3. `NetworkSnapshotJSONCodec.swift` 和 Domain Network模型：v2写/v1读，十进制整数、不伪造旧方向起点、8MiB失败语义、数据与声明是否一致。
4. `UsageButlerInfrastructure/Network/GetifaddrsInterfaceCountersReader.swift`：实际已为sysctl64位实现；缓冲边界、失败、接口消失；名称保留不代表32位实现。
5. `UsageButlerUI/Network/`、`MenuPanelViewModel.swift`：540pt，五档可达，未知与新鲜度，真实/演示区分、键盘焦点、导出白名单。`NetworkDemoApplicationsView`必须在Release被排除。
6. `NetworkCollector.swift`、`UsageButlerApp/`：start/stop/restart、旧session heartbeat、后台发布、正常退出；`SettingsRootView`检查飞书配置变动后的旧结果失效。

已执行：完整XCTest、固定回归、当前原生窗口交互、64位解析及本机受控回环传输。没有把JS原型测试算作XCTest；未声称完整VoiceOver、两小时真实浸泡、全部代理拓扑或x86_64真机执行通过。源码或自动测试无法独立证明安装/运行，请把无法现场复验的项目列为Unknown。

请单独判断：R1–R7还有哪些缺陷？哪些仅为开发预览边界？现有测试是否掩盖合同变化？是否有新增隐私/性能风险？无需重新实现HTML原型，不要把真实应用采集或阻断写成已经实现。
