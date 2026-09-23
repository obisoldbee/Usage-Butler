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

0.3.1 使用公开 Darwin sysctl CTL_NET/PF_LINK/NETLINK_GENERIC/IFMIB_IFALLDATA/0/IFDATA_GENERAL 的 ifmibdata.ifmd_data。读取有界缓冲，检查完整记录长度、空接口和名称边界；失败返回明确失败；成功空数组表示完成枚举但无接口，不混入零值或 32 位 fallback。源 class 原名 GetifaddrsInterfaceCountersReader 为兼容保留。

0.3.0 的 NET_RT_IFLIST2 假设已被真机反例否定：虽然结构字段为 UInt64，Apple XNU 的非平台进程分支会将字节计数转换为 UInt32，产生 4 GiB 回绕。结构声明和合成 parser 测试不能证明真实来源位宽。证据：[Apple rtsock.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c)、[Apple if_mib.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_mib.c)。新读取器使用普通用户权限，无平台签名、提权或私有 entitlement；真机回归把实际读数夹在两次系统 netstat 读数之间。

SystemConfiguration路径独立时效，15秒未更新降为未确认；UI不得猜Wi-Fi或代理软件归属。所选接口速率超过12秒或源时间在未来，显示未知。全局历史 reset 只在诊断显示，当前健康依据所选接口的新鲜两向速率。顶部重新起算提示须同时满足：对应方向有 breakReason、起点位于当前选择范围内、范围内该起点之前有已知速率。初始基线、启动前空白、范围外旧中断和未验证旧起点均不告警；原因与时点在设置 → 网络 → 当前采样信息中保留。

## 图表与交互

红上蓝下，独立0基线轴，12%留白，nice上限1/2/3/5/8/10；扩张立即、缩小45%/8秒滞回，单调时间。两图共享now/range/inspection，五档独占行。键盘查看原始点，鼠标查看不插值；未知/缺口保留。NSView仅处理图表焦点下的方向/Home/End/Space/Escape，表单 Tab 优先。裸 Tab 在三个页面统一循环（额度→内存→网络→额度），不能整页跳过网络。

Debug演示UI与生产采集分离，Release条件编译排除演示应用/目标。演示规则仅草稿。导出用字段白名单、默认别名、预览后NSSavePanel/SwiftUI exporter本地保存；取消不写，失败展示。不输出路径/PID/凭据或网络内容。

## 生命周期与验证

新会话拒绝旧会话心跳与迟到事件。stop取消消费者/发布流；正常退出等待收尾且有有界deadline。离线测试、原生窗口、安装位哈希签名、running executable、remote commit/tree分别记录。无真实应用/目标观察、无防护；VoiceOver/睡眠/代理拓扑与性能未执行项不得推成PASS。

## 0.3.2 面板与设置交互

五档 plain 按钮在扩展后的 label 上设置 Rectangle contentShape，32pt最小高度；装饰边框不参与命中。网络主面板不使用 DisclosureGroup，不插入条件性的游标/抽稀说明行；游标占固定行，降低实时测量导致的原生面板高度变化。网络概览事务禁用动画。

Settings scene 的共享选择状态区分通用与额度、网络。0.3.5 起统一从顶栏齿轮打开设置，网络页集中正常采集状态、采集开关、统计对象、能力说明与诊断；主面板移除重复的“网络设置…”入口及未接入能力占位，只保留趋势和非健康/范围内历史中断提示。macOS14+保留 SettingsLink、macOS13保留现有AppKit fallback。网络采集开关继续读取采集器确认值；观察选择只改变显示对象，不改变真实网络路由。

## 0.3.3 生命周期、presence 与呈现补充

`NetworkCollector` 使用已注入的 ClockPort / NetworkSettingsStore。启停意图在首次 await 前作用于运行时，保存按接收顺序串行；保存后不再执行启用逻辑。start.load 和发布时钟 await 后校验代际。停止后 policy/refresh 不创建发布循环；启动前可以保存意图，普通 stop 可以重启。最终 shutdown 关闭新任务接收并 drain 已接受保存，失败保存不会阻挡即时停用，也不承诺跨重启偏好已经持久化。

`InterfaceCountersReading.read()` 返回成功完整数组或失败。source 每次轮询只发一个 interfaceEnumeration 事件；其 envelope 是会话、顺序、时间和完成边界。单个 legacy interfaceCounters 事件不能证明其它接口缺失。snapshot 的可选 interfaceInventory 保留成功状态、全部名称和 envelope；presence(of:) 只从当前成功清单证明 present/missing，失败/断连为 unknown，停止为 notObserved。

接口原始 counter/历史与当前 presence 分开。最多64个接口历史，每接口7200点；新接口可淘汰最旧已缺失历史并公开 truncation。失踪、枚举失败恢复、会话变化和可证明的 systemIdentity/index 变化，均重建两向基线；不得结算未知间隔字节。index 不是硬件身份，不能识别两次轮询之间同 index 的销毁重建。没有证据时不伪造此归因。

schema 仍为 v2，新增可选 interfaceInventory/systemIdentity 和各方向 continuity ID；旧v1/v2缺少枚举时 unknown，不能从历史键升级。新增 sequence/monotonic 仍写十进制字符串，inventory 会话必须等于 snapshot、sequence 不得超过 appliedSequence；失败不能带 present 名称，重复/空名字/过大清单拒绝。编码/解码均维持8MiB界限。

路径的5秒读取复用和15秒确认窗口统一使用 NetworkPathCache 的注入单调时间（15秒边界即过期）；墙钟只记录显示。单调时间倒退或未来确认无效。读取失败不延长最后成功确认；休眠和唤醒均撤销确认，唤醒重新读取。设置页独立 tick 不依赖流量或 Provider 发布。

NetworkRateSample.sampleID 由 source/interface/session/epoch/monotonic 组成。采集侧为各向连续段保存锚点，裁剪后仍保留；legacy 无锚点时先在完整历史分段，再裁切可见范围。真实 nil、gap、source/interface/session/epoch 和倒序仍强制断段。点 ID 与绘图段 key 分开。缓存 key 包含完整数据 revision、接口、now/window、采样合同和抽稀限额；数据 revision 同时覆盖连续性、方向和基线改变。缓存保留原始峰值、峰谷抽稀、孤立点和随时间推进的空白。

原始 observedPeak 可空，视觉与 AX 共用，只有轴使用 nil→0 fallback。游标使用原始样本索引；Chart 标记不依赖游标状态，独立 overlay 负责固定线。Escape 清除读数并归还 AppKit first responder，表单/Picker Tab 仍优先。
