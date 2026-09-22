# 网络 v2 独立 Review 入口

范围：macOS 原生 0.3.1（4）修复，对照公开父提交 `c4386a975477d61f5458bb926f5bace8a0008625`；更早网络 v2 的背景可追溯到 `706824e4cc07914f4d8b55a89965cfd7c72ecb9e`。不要将旧归档里的未修复描述或设计包指令当成当前事实。

先读 `network-redesign-brief.md` 和 `network-v2-contract.md`，再核对源码与测试，区分 Observed / Inferred / Unknown。优先寻找可复现缺陷，给严重性、触发条件、文件行号、影响与最小修复建议。

1. `UsageButlerCore/Network/NetworkAggregator.swift`：各向baseline/epoch/reset/missing/gap；有意义的0和nil；UInt64溢出；源事件重放/乱序。
2. `NetworkRateHistoryBuffer.swift`、`NetworkChartProjection.swift`、`NetworkChartAxis.swift`：后台源历史、局部cadence、wall回拨、单调时钟、分段先于抽稀、峰值、独立刻度与共用游标。
3. `NetworkSnapshotJSONCodec.swift` 和 Domain Network模型：v2写/v1读，十进制整数、不伪造旧方向起点、8MiB失败语义、数据与声明是否一致。
4. `UsageButlerInfrastructure/Network/GetifaddrsInterfaceCountersReader.swift`：0.3.1 改为公开 IFMIB_IFALLDATA/IFDATA_GENERAL；不能将 64 位结构等同于真实 64 位值。核查实际读取与 netstat 前后夹取测试、完整记录边界和接口消失。
5. `UsageButlerUI/Network/`、`MenuPanelViewModel.swift`：540pt，五档可达，未知与新鲜度，真实/演示区分、键盘焦点、导出白名单。`NetworkDemoApplicationsView`必须在Release被排除。
6. `NetworkCollector.swift`、`UsageButlerApp/`：start/stop/restart、旧session heartbeat、后台发布、正常退出；`SettingsRootView`检查飞书配置变动后的旧结果失效。

已执行：完整XCTest、固定回归、当前原生窗口交互、64位解析及本机受控回环传输。没有把JS原型测试算作XCTest；未声称完整VoiceOver、两小时真实浸泡、全部代理拓扑或x86_64真机执行通过。源码或自动测试无法独立证明安装/运行，请把无法现场复验的项目列为Unknown。

请单独判断：R1–R7还有哪些缺陷？哪些仅为开发预览边界？现有测试是否掩盖合同变化？是否有新增隐私/性能风险？无需重新实现HTML原型，不要把真实应用采集或阻断写成已经实现。

## 0.3.1 定向复核

重点检查 `NetworkStatusRules.historyRestartNotice` 的范围和启动空白处理，以及 `PanelPresentationController` 对 `PanelTabRouting.shouldCyclePage` 的统一调用；local monitor 必须保留 nil 消费结果，不能又把 Tab 交回 AppKit。`NetworkHistoryNoticeTests` 覆盖历史范围、初始基线、各方向未知；`PanelTabRoutingTests` 覆盖三页两轮回环、输入焦点与修饰键。阅读 UI 代码时确认“统计说明”保留各方向起算原因和时点。
