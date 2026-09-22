# 网络 v2 原生技术合同

状态：本轮采纳；实现与验证见当前 review。SwiftUI/macOS 13，不引入 WebView。

## 数据与分层

Domain 保存 nullable、source/session/epoch 和 per-direction 段；Infrastructure 读取系统；Core 结算、保留源历史、分段与轴模型；UI 只选择/显示/交互。NetworkCollector 单一源所有者，可见1Hz、后台0.2Hz只限制发布。源约1Hz采样。

每个接口最多7200点并按单调时间裁剪2小时，接口数受既有聚合上限约束。快照包含完整有界 rateHistory，UI替换批次，不从发布时间补历史。重复source monotonic不增长，session变化允许单调时间重置；接口/会话/epoch/来源隔离。源采样间隔随点保留，图表不得根据当前可见窗口重新估计。缺失cadence保留nil，兼容投影使用显式保守nominal1s而非推断旧历史。

分段先于抽稀；每向按已知采样/epoch/session/单调顺序和本地cadence处理，真实缺口>2.5倍声明间隔（最少2秒）断线。上下行独立未知。峰谷抽稀保留端点，源样本不因绘图减少。

## 累计

DirectionByteTotal = bytes? + since? + sinceMonotonic? + breakReason?。本段累计，只结算连续且同epoch的整数差值；单向counter下降、缺失/恢复、epoch变化和长采样静默重建该方向基线。基线bytes=nil；第二个同段读数才可为已知0。另一方向不受无关reset影响。UInt64相加必须检查溢出。

此为明确合同升级：旧testNewEpochReBaselinesWithoutDiscardingSettledBytes保留跨epoch总数的预期被替换；旧reset当下0改为未知。不是为让旧测试绿而静默改预期。

## JSON

usagebutler.network.snapshot version=2；保留v1读取。v2总量采用uploadSegment/downloadSegment，UInt64、sequence、monotonic均十进制字符串。v1总量可保留数字但since与sinceMonotonic为nil，breakReason=legacy-unverified；不能从旧共享日期推导独立起点。history/cadence为可选字段，旧数据不存在时不伪造。编码和解码默认均有8MiB上限；全接口长历史超过限制时明确失败，不生成自身无法读取的文件。内存快照发布不经过JSON编码，导出方需另外选择范围或接口。

## 接口来源

0.3.1 使用公开 Darwin sysctl CTL_NET/PF_LINK/NETLINK_GENERIC/IFMIB_IFALLDATA/0/IFDATA_GENERAL 的 ifmibdata.ifmd_data。读取有界缓冲，检查完整记录长度、空接口和名称边界；失败返回无读数，不混入零值或 32 位 fallback。源 class 原名 GetifaddrsInterfaceCountersReader 为兼容保留。

0.3.0 的 NET_RT_IFLIST2 假设已被真机反例否定：虽然结构字段为 UInt64，Apple XNU 的非平台进程分支会将字节计数转换为 UInt32，产生 4 GiB 回绕。结构声明和合成 parser 测试不能证明真实来源位宽。证据：[Apple rtsock.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c)、[Apple if_mib.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_mib.c)。新读取器使用普通用户权限，无平台签名、提权或私有 entitlement；真机回归把实际读数夹在两次系统 netstat 读数之间。

SystemConfiguration路径独立时效，15秒未更新降为未确认；UI不得猜Wi-Fi或代理软件归属。所选接口速率超过12秒或源时间在未来，显示未知。全局历史 reset 只在诊断显示，当前健康依据所选接口的新鲜两向速率。顶部重新起算提示须同时满足：对应方向有 breakReason、起点位于当前选择范围内、范围内该起点之前有已知速率。初始基线、启动前空白、范围外旧中断和未验证旧起点均不告警；原因与时点在设置 → 网络 → 当前采样信息中保留。

## 图表与交互

红上蓝下，独立0基线轴，12%留白，nice上限1/2/3/5/8/10；扩张立即、缩小45%/8秒滞回，单调时间。两图共享now/range/inspection，五档独占行。键盘查看原始点，鼠标查看不插值；未知/缺口保留。NSView仅处理图表焦点下的方向/Home/End/Space/Escape，表单 Tab 优先。裸 Tab 在三个页面统一循环（额度→内存→网络→额度），不能整页跳过网络。

Debug演示UI与生产采集分离，Release条件编译排除演示应用/目标。演示规则仅草稿。导出用字段白名单、默认别名、预览后NSSavePanel/SwiftUI exporter本地保存；取消不写，失败展示。不输出路径/PID/凭据或网络内容。

## 生命周期与验证

新会话拒绝旧会话心跳与迟到事件。stop取消消费者/发布流；正常退出等待收尾且有有界deadline。离线测试、原生窗口、安装位哈希签名、running executable、remote commit/tree分别记录。无真实应用/目标观察、无防护；VoiceOver/睡眠/代理拓扑与性能未执行项不得推成PASS。

## 0.3.2 面板与设置交互

五档 plain 按钮在扩展后的 label 上设置 Rectangle contentShape，32pt最小高度；装饰边框不参与命中。网络主面板不使用 DisclosureGroup，不插入条件性的游标/抽稀说明行；游标占固定行，降低实时测量导致的原生面板高度变化。网络概览事务禁用动画。

Settings scene 的共享选择状态区分通用与额度、网络。主面板“网络设置…”先选网络再通过 OpenSettingsAction（macOS14+）或现有AppKit fallback（macOS13）打开独立设置；不在实时面板中承载设置。网络采集开关继续读取采集器确认值；观察选择只改变显示对象，不改变真实网络路由。
