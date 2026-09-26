# 0.3.4（7）网络图表内存整改

## 采纳需求

持续更新网络趋势时，轴标签和视图对象必须有界。每秒推进时间、切换五档范围、调整独立纵轴，都不能永久保留离开界面的刻度。真实日期/字节速率、缺口、孤立点、峰值、独立刻度、联动悬停与辅助功能语义保持一致。加速绘图验证和整机长期运行验收分别记录。

## Observed：问题和对照

基线为 0.3.3（6），公开源码 1c84e9321d0d0235b0bb4bfe48e10e99832da5bc。同一安装进程运行约 18 小时后，macOS 27.2（26B5091g）测得 physical footprint 约 5.5 GiB，堆中有 253,533 个 Charts.MeasurableAxisLabel，SwiftUI 跟踪字典合计约 2.19 GB。resident 较低是大量内存已换出，不能据此否定占用。

网络图表每次刷新将三个新 Date 值传给 AxisMarks。同一系统的离线双图对照，各执行 3,000 次时钟更新、6,002 次图表 body 求值：原日期轴留下 18,012 个轴标签，结束 footprint 408,716,392 bytes；固定坐标轴留下 12 个标签，结束 footprint 30,475,056 bytes。原日期轴的标签随更新次数增长，类型分布与故障进程一致。这定位本次主要增长路径，不证明框架内部所有保留关系或应用其他潜在增长均已排除。

## 实现

- NetworkChartCoordinates 使用固定 0/0.5/1 绘图刻度，标签按当前窗口和独立上限反算。采集合同、原始点/段身份不变，不依赖反复销毁 Chart 或重启。
- NetworkInspectionOverlay 将鼠标坐标反算为真实 Date；固定游标随窗口移动。
- mark 标签和 NetworkChartAccessibility 使用原始时间、B/s、连续段与孤立点，Audio Graph 不暴露归一化数值。
- NetworkChartCoordinatesTests / NetworkChartAccessibilityTests 验证五档范围、往返换算、100 倍量级、零、范围外值以及辅助功能原始单位/缺口。

## 复现入口

框架对照仅使用合成数据，不启动应用 Runtime、Provider 或读取配置：

```sh
mkdir -p .build/memory-axis
xcrun swiftc -O -parse-as-library script/diagnostics/network_axis_memory_probe.swift -o .build/memory-axis/AxisProbe
.build/memory-axis/AxisProbe date 3000 0.02
# 出现 complete 后记录 heap -s --noContent <PID>，退出该测试进程，再执行对照。
.build/memory-axis/AxisProbe normalized 3000 0.02
```

实际生产 NetworkPlotView 的 Debug 专用入口仅在显式离线环境启用。先退出旧应用，使用当前构建，准备一个没有同名结果的新目录：

```sh
mkdir -p .build/memory-regression
USAGE_BUTLER_OFFLINE_FIXTURE=1 .build/DerivedData/Build/Products/Debug/Usage-Butler.app/Contents/MacOS/Usage-Butler --validate-network-memory="$PWD/.build/memory-regression" > .build/memory-regression/run.jsonl
```

入口执行 10,000 次数据/时钟更新，循环 60/300/900/3600/7200 秒五个代表窗口和独立上限，含缺口、孤立点与点替换；每千次记录 footprint/resident/body 次数，结束保存实际窗口 PNG，保留进程供 heap 检查，之后退出测试进程。它不是五个产品按钮的点击走查；实际产品五档 60/600/1800/3600/7200 秒的换算另由单元测试验证。入口及合成数据不进入 Release。本轮 open 启动返回 -10810，随后使用签名验证通过的同一 Debug 可执行文件直接启动；不把 LaunchServices 失败记为通过。

## 验收边界

当前全套 XCTest 805 项/0失败，Universal Release 构建通过。实际图表压力测试、安装与长期运行以对应收据为准。加速更新不能等同于 18/24 小时真实采集；macOS 13、x86_64 实机、完整 VoiceOver、系统输入到屏幕性能仍需分别验证。历史 801 项测试未覆盖本次持续渲染分配问题。本轮不修改 Provider、凭据、通知、采集缓冲或数据落盘。

最终实际 NetworkPlotView：10,000 次更新/10,001 次 body 求值（约400.49秒），启用AX读回后轴标签24个、再次heap仍24个；更新期间footprint 110,085,176～111,412,280 bytes，结束49,628,216 bytes。此前无AX的独立/原生对照均12个，额外有界副本的系统内部成因未单独证明。CUA确认每个样本独立的真实时间与速率。等待器300秒超时后，对同一存活PID继续取证确认完成；未将超时记为通过。最终805测试/0失败。加速合成负载不等于18小时真实运行。

## 0.5.3（14）接口历史时间到期的分配门

固定1Hz的满点输入主要触发7200点裁剪；实际定时器稍晚时，两小时到期会先触发。0.5.2的独立所有权探针中，26接口×7200点每次到期清理均重新分配26个数组，即使没有外部快照；40轮共1040次。字典键视图在移除/修改值期间保留旧数组，产生了非必要写时复制。此结果证明分配开销，不能单独证明无限保留或正式GUI整个峰值的原因。

到期清理现在先保留独立键列表，再修改历史。唯一所有者可以原地裁剪，真正被已发布快照共享的数组仍通过必要COW保证快照不变。采样、未知/缺口、session/epoch、每接口7200点和两小时单调期限保持原义；没有加入allocator清理调用，也不改后台14天存储/schema。

回归分别检查唯一owner、已发布snapshot、后续唯一写入、自定义容量和回退时钟。性能验收必须把自然增长后的Array.capacity与count分开，并分别测量点数裁剪、时间漂移到期、慢消费者及纯图表投影。缓冲数量/在用malloc、分配器预留、footprint和生命周期峰值不能互相替代；释放活对象不保证footprint即时回落。纯逻辑合成实验不覆盖SwiftUI绘制、真实24小时/周级运行或所有系统版本，正式安装和资源窗口以对应版本的独立收据为准。
