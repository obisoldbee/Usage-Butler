# Usage-Butler（额度管家）

Usage-Butler 是一款 macOS 菜单栏应用，用于在一个界面中查看 AI 编程订阅的额度状态、刷新时间和本机内存概览。

> 当前官方支持范围仅覆盖以下 **4 类订阅/套餐的额度展示**：
>
> 1. OpenAI Codex
> 2. MiniMax Token Plan
> 3. 火山方舟 Agent Plan
> 4. 火山方舟 Coding Plan
>
> 它们来自 **3 个 Provider**：OpenAI、MiniMax 和火山方舟。OpenAI CLI 实际返回的 Codex Spark 或其他未知额度桶，可能作为 Codex 概览的明细出现，但不构成新增的官方支持订阅。

本项目只读取和展示额度信息，不提供订阅购买、升级或额度重置能力。

## 当前能力

- 从本机 Provider CLI 读取订阅额度，并展示数据新鲜度与刷新状态。
- 显示系统内存概览和有界的本地历史记录。
- 支持系统通知；安装并配置 `lark-cli` 后可选用飞书通知。
- Provider 不可用、未登录或数据过期时，显示明确状态，不伪造可用额度。

## 环境要求

- macOS 13 或更高版本
- Xcode（支持 Swift 6）
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45.4 或更高版本
- 按需安装并登录以下本机 CLI：
  - `codex`：OpenAI Codex
  - `mmx`：MiniMax Token Plan
  - `arkcli`：火山方舟 Agent Plan / Coding Plan
  - `lark-cli`：可选，仅用于飞书通知

各 CLI 由对应项目独立提供和授权，本仓库不包含这些 CLI，也不代替其登录流程。

## 构建与验证

在仓库根目录执行：

```bash
# 验证 XcodeGen 生成结果稳定，并列出工程配置
./script/verify_generated_project.sh

# 生成工程并运行单元测试
./script/test.sh

# 生成、构建并启动 Debug 应用
./script/build_and_run.sh
```

`UsageButler.xcodeproj` 是生成产物，不纳入版本控制。

## 隐私与本地数据

- 应用和仓库不内置 Provider token、API key、Cookie 或用户登录资料。
- Provider 登录状态由本机的 `codex`、`mmx` 和 `arkcli` 管理。调用这些 CLI 时，CLI 可能按照其自身行为连接对应 Provider 网络。
- 规范化后的额度缓存写入 `~/Library/Application Support/Usage-Butler/quota-cache/v1/`。
- 内存历史写入 `~/Library/Application Support/Usage-Butler/memory-history/v1/`。
- 开关、刷新周期、CLI 路径、通知去重标记等偏好通过 macOS `UserDefaults` 保存到应用标识 `io.github.obisoldbee.UsageButler` 的偏好域。
- 系统通知只在本机显示。飞书通知是可选功能；启用后，通知内容会由本机 `lark-cli` 发送到用户配置的目标会话。

仓库不预置飞书会话 ID。需要飞书通知时，可由用户在本机显式配置：

```bash
defaults write io.github.obisoldbee.UsageButler \
  usageButler.settings.v1.quotaAlerts.larkChatID "oc_your_chat_id"
```

未配置有效目标会话时，飞书通知不会启用，系统通知仍可使用。删除配置可执行：

```bash
defaults delete io.github.obisoldbee.UsageButler \
  usageButler.settings.v1.quotaAlerts.larkChatID
```

## 发布状态

当前版本是开发预览版。仓库暂不提供可下载的 Release 二进制；本地脚本生成的是未签名、未经过 Apple 公证的开发构建，不应视为正式分发包。

## 许可证

代码使用 [MIT License](LICENSE) 开源。第三方产品名称和商标的归属说明见 [NOTICE.md](NOTICE.md)。
