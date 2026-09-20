# 网络模块整改与原型交付说明

更新：2026-09-20。本文是当前源码的已知问题与下一版设计输入，不代表问题已经修复或完整网络模块已经交付。

## 已有实现与边界

- 原生 macOS SwiftUI 菜单栏应用；已有额度、内存、网络三页，540pt 宽度、内容自适应高度。
- 网络 production 当前只有 getifaddrs 接口字节/速率、系统确认的观察接口、会话累计、有限内存趋势、启停及覆盖状态。
- 图表已有方向/会话/epoch/连续段 series，上传红、下载蓝；源样本去重、缺口保留；网络自动选择使用 SystemConfiguration，不猜 BSD 名含义，不相加物理口和 TUN。
- 按应用列表、搜索排序关注、五类详情和 JSON 导出尚未完成。没有实际按应用/目标采集，也没有连接阻断能力。N2 完整 UI 与 P0 真实观察均未验收完成。
- Debug harness 的自渲染图证明受控输入下的 Charts 绘制；不等同真实用户窗口、键盘、显示缩放与运行生命周期全部验收。

## 用户已确定的新方向

上传和下载分成两个图表区域，默认上方上传（红）、下方下载（蓝）；共享横轴时间范围，但纵轴分别自适应、分别显示单位/刻度/峰值。“两图区间独立”指纵轴流量量级独立，不是各自显示不同时间范围。这样下载很大时不会压扁较小上传。

可提供类似活动监视器的上下镜像备选视觉稿，但不能把两方向叠在同一个共享量级坐标系里，也不能隐藏独立刻度，让用户误以为两边等高代表等速。零基线、轴单位必须明确，方向不能仅靠颜色分辨。默认展示两块清楚标记的图。

## Review：需要解决的问题

| ID | 证据与影响 | 整改要求 |
|---|---|---|
| R1 / P2 | 当前 `NetworkOverviewView` 只有一个 Chart 共用纵轴。上下行量级差异或历史尖峰会把小流量压到零轴附近 | 两方向上下分区、独立纵轴、共享时间轴；刻度扩张/收缩策略防抖；全零、极小值、突发和历史不足都有设计 |
| R2 / P2 | 用户实际截图中五档时间按钮超出卡片右侧；源码标题和固定宽 segmented Picker 同排 | 540pt 下五档全显示、全部可点击；必要时单独一行。小可用高度/长文案/键盘焦点可用，禁止裁切 |
| R3 / P1 | `NetworkChartSamplingContract.effectiveGapThreshold` 取当前窗口全体间隔中位数；历史在隐藏时约 5 秒发布、打开后约 1 秒。当新密样本占多数，阈值约 2.5 秒，旧的正常 5 秒样本被重新判断为断档，产生散点 | 明确源采样与 UI 发布合同；每段记录 cadence / gap 原因，不用当前窗口单个中位数重解释历史。固定混合 5s→1s 数据集随窗口滚动测试；真实缺口仍不能连上 |
| R4 / P1 | `NetworkAggregator.settle` 单方向 reset 只清该方向累计，却重写上下行共用 `SessionByteTotal.since`。如先累计上传 5000、下载 8000，之后下载 reset，上传仍 5000 却标成新起点之后所得；既有 `testDirectionsBreakSeparately` 未校验这个共享起点 | 每方向独立统计起点，或同时重置且明确损失；展示层不能用一个不成立的起点描述两个不同时间范围的累计 |
| R5 / P2 | getifaddrs 的 32 位计数回卷按 reset 报告；截图长期橙色且显示多次重置。该计数是聚合器所有接口累计，不能据截图说当前接口重置同样次数 | 分开当前采集健康、历史不完整、当前所选接口的统计；按来源/方向列明问题，详情再显示诊断。评估更稳健的计数来源/回卷处理需原生验证，禁止只隐藏真实异常 |
| R6 / open | Debug harness 中 `NSApp.terminate` 挂住已有记录，生产用户 Quit 路径尚未复验 | 后续原生任务单独复验并修复生命周期；HTML 原型不能证明已解决 |
| R7 / incomplete | 页面底部只有“无法按应用统计”占位，完整 N2 的列表、五详情、导出/状态尚缺 | 原型同时交付真实能力受限与完整演示两套明确状态；原生实现仍须逐项接入，不能用原型数据冒充真实来源 |

R3 是可由源码推演的采样切换缺陷，和截图散点现象吻合；截图本身不能证明所有散点都来自同一原因，需受控原生复现。R4 是当前代码与测试输入可确认的合同不一致。以上功能缺口不阻止将明确标注的开发切片源码公开；不作为稳定完成版或防上传工具发布。

## 信息层级

1. 紧凑状态行：采集中/停止/断连 + 仅监控/防护未开启。当前健康和历史警告分离。
2. 网络选择：自动 + 友好名称；高级接口收起。物理/TUN 不相加，未知来源不猜。
3. 两方向当前速率和有真实口径的累计；原始接口值、reset 次数、统计起点细节折叠到说明。
4. 上传/下载独立图区，共享五档时间选择（1 分钟、10 分钟、30 分钟、1 小时、2 小时，默认 1 小时），共享悬停/键盘时间点，两边数值联动；较小流量也可读。
5. 按应用列表与详情。受限态解释缺失与下一步，避免整页堆满大号诊断卡片。

## ChatGPT 需要交付的新包

交付的是**设计 + 可运行交互原型 + 原生接入说明**，不是已经工作的 Swift/macOS 网络采集服务。

- ZIP 内 `README.md`：打开方法、文件树、修改清单、能力边界、原型测试结果与未验证项。
- `network-prototype.html`：单文件离线可运行、内嵌资源、无 npm/CDN；同时给可维护的 HTML/CSS/JS 拆分源码。可以在同一 ZIP 提供 `src/`，但明确它是 Web 原型源码。
- 设计 PNG：540pt 菜单栏概览浅/深色；上下行量级差异 100 倍；长窗口尖峰；历史缺口；未启用/部分覆盖/断连；应用列表与五类详情（趋势/连接/域名IP/进程/规则）。宽屏工作台可作补充，不替代菜单栏稿。不给真实背景桌面信息。
- 交互完整：五档时间、自动/手动/不可用网络、搜索排序关注、详情返回、暂停/恢复演示、JSON 导出预览/脱敏/取消、规则草稿但无真实阻断。
- 确定性 fixture：上下行量级悬殊、单向/双向零与未知、缺口、单点、5s→1s 采样切换、旧快照重发、epoch/接口切换、重置和计数不可用。示例标“演示数据”，不伪装实时采集。
- `DESIGN_SPEC.md`：布局/间距/字号/色彩/深色/AX、两图区独立刻度及缩放防抖、时间轴联动、状态层级和溢出约束。
- `contracts/network.d.ts` 与示例 JSON：明确 schemaVersion、sample identity/time/cadence、gap reason、各方向累计起点、coverage/freshness、真实能力；缺失是 null，不补零。沿用现有 Swift 语义，变化列 migration 表。
- `MAC_INTEGRATION.md`：现有 SwiftUI 文件映射、可复用逻辑、原生待修问题、接口与应用来源边界；别把 HTML 当生产主界面，也不强行引入 WebView。
- `AGENT_PROMPT.md`：给后续 Codex 的分步接入与验收清单，不把未验证能力标完成；`QA.md` + 可执行的离线原型测试。实际跑过才报告 PASS，不复用旧包“120 项”的说法。

若无法读取 GitHub 源码或无法实际生成 ZIP，应明确说明并索取所需源码/附件，不假装已访问。用户会在原设计对话中提供截图，截图作为问题证据而非需要像素照抄的最终设计。

## 重点源码入口

- `UsageButlerUI/Network/NetworkOverviewView.swift`
- `UsageButlerUI/Menu/MenuPanelViewModel.swift`
- `UsageButlerCore/Network/NetworkChartProjection.swift`
- `UsageButlerCore/Network/NetworkRateHistoryBuffer.swift`
- `UsageButlerCore/Network/NetworkAggregator.swift`
- `UsageButlerCore/Network/NetworkCollector.swift`
- `UsageButlerDomain/Network/NetworkCounters.swift`
- `UsageButlerInfrastructure/Network/GetifaddrsInterfaceCountersReader.swift`
- `UsageButlerTests/Network/NetworkSessionTotalTests.swift`

保留隐私边界：不做 HTTPS 解密、载荷采集、凭据读取、流量上传或自动发送消息；任何真实防护能力另有独立规格与真机门。
