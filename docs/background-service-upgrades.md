# 后台服务的打包与升级

本流程适用于已有工作后台安装的本地升级。候选构建、静态签名验证、正式注册、实际采集恢复分别留证。完成前两项不代表后台已恢复。

## 候选版本与构建

`project.yml` 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 是主应用版本来源；`Config/Info.plist` 从这两个构建设置展开。同步更新 `BackgroundNetworkWire.version`，使 helper 状态响应携带同一个版本。重新生成工程，核对 `xcodebuild -showBuildSettings` 和最终包中的值；不要只修改生成产物的 Info.plist。

维护独立的本地交付记录，记录每个已尝试正式注册的 build 及其包摘要。可执行文件、签名或包内容返修后，build 必须严格大于所有已尝试正式注册的 build，即使上次启动失败或已经退回旧版本。一个 build 只交付一份冻结候选；冻结后不原地重签或替换其中的文件。

使用新的任务专属构建目录，从已提交源码生成 Universal Release。例如，在仓库根目录设置一个尚不存在的 `CANDIDATE_ROOT` 后执行：

```bash
set -euo pipefail
: "${CANDIDATE_ROOT:?Set a new task-owned output directory}"
test ! -e "$CANDIDATE_ROOT"
mkdir -p "$CANDIDATE_ROOT"
xcodegen generate --no-env --spec project.yml --project .
xcodebuild -project UsageButler.xcodeproj -scheme UsageButler \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$CANDIDATE_ROOT/Universal" \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

`script/build_and_run.sh` 是 Debug 开发入口，默认签名与启动行为不构成正式升级流程。候选构建阶段不启动主应用或 helper，不触发后台注册。

## 同一身份与嵌套签名

在停止工作安装之前保存其 App/helper 摘要、各架构签名标识、指定代码要求（DR）和叶证书指纹。保留可核对的工作包。通过本机私有配置选择同一现有签名身份，分别核对 App 和 helper 的叶证书；仅相同 Team ID 或通过 DR 不等于完全相同的签名身份。身份、证书指纹和含本机身份的原始签名输出留在私有交付证据中，不写入仓库、公开日志或摘要。

检查候选的固定标识与相对路径：

| 项目 | 值 |
| --- | --- |
| App bundle/signing identifier | `io.github.obisoldbee.UsageButler` |
| helper signing identifier | `io.github.obisoldbee.UsageButler.NetworkAgent` |
| LaunchAgent label / Mach service | `io.github.obisoldbee.UsageButler.network-agent` |
| BundleProgram | `Contents/MacOS/UsageButlerNetworkAgent` |

先签最终包内 helper，再签包含它的 App。以下操作要求 `CANDIDATE_APP` 指向尚未交付的构建包，`USAGE_BUTLER_CODESIGN_IDENTITY` 来自已核对的本机私有配置；不提供 ad-hoc 默认值，不开启 shell tracing：

```bash
set -euo pipefail
: "${CANDIDATE_APP:?Set the candidate bundle path}"
: "${USAGE_BUTLER_CODESIGN_IDENTITY:?Select the existing working identity}"
test "$USAGE_BUTLER_CODESIGN_IDENTITY" != '-'
codesign --force --sign "$USAGE_BUTLER_CODESIGN_IDENTITY" --timestamp=none \
  --identifier io.github.obisoldbee.UsageButler.NetworkAgent \
  "$CANDIDATE_APP/Contents/MacOS/UsageButlerNetworkAgent"
codesign --force --sign "$USAGE_BUTLER_CODESIGN_IDENTITY" --timestamp=none \
  --identifier io.github.obisoldbee.UsageButler \
  --entitlements Config/UsageButler.entitlements "$CANDIDATE_APP"
codesign --verify --all-architectures --strict \
  "$CANDIDATE_APP/Contents/MacOS/UsageButlerNetworkAgent"
codesign --verify --all-architectures --deep --strict "$CANDIDATE_APP"
```

对每个架构再用工作包的对应 DR 通过 `codesign --verify -R` 分别验证新 App 和 helper，并确认叶证书匹配。检查两份可执行文件均含 `arm64` 和 `x86_64`、最终版本正确、LaunchAgent 内容一致、entitlements 未扩大。记录源提交/tree、完整包文件清单与 SHA-256、App/helper SHA-256、归档 SHA-256。复制归档时保持包字节，复制后重验摘要和嵌套签名。Apple Development 本地签名不代表 Developer ID 分发或公证通过。

## 正式替换顺序

1. 候选通过上述检查之后，记录原后台启用意图和历史进度，保留当前工作包及恢复所需证据。保留用户数据库及其新增记录。
2. 在旧包仍在原安装位置时，经既有生产控制器停止采集并调用 `SMAppService.unregister()`。等待异步注销完成和可观察的服务注销状态，核验属于该安装的 helper 及其 nettop 子进程已退出。仅结束 GUI、发送进程信号或等待固定秒数不满足此门槛；注销未确认就不换包。
3. 退出旧 GUI，替换整个安装包，不就地修改已登记包内的二进制。核验安装后的版本、文件摘要、App/helper 签名和 DR；通过正式包路径正常打开，按原启用意图经生产路径注册。不得按模糊显示名、直接执行 helper 或另建 label 启动。
4. 注册完成后独立核验 helper 的 PID、可执行路径、SHA 和版本，以及唯一自有 nettop。确认真实采样游标和已提交历史持续新增、原记录保留；退出 GUI 后仍新增，再正常重开读取。注册返回成功或 DR 通过都不能替代这些运行时证据。
5. 失败时保留日志和真实停采缺口，恢复已验证工作包及用户原启用意图，重新核验采集。恢复旧包不撤销较新 build 的占用记录。不补零，不以旧数据库覆盖已有数据，不用 `resetbtm`、手工 bootstrap、修改服务 label 或安全审批掩盖失败。恢复未验证时保留所有回退材料并明确报告失败。

启动约束错误与后续相对路径解析错误分别记录。只有日志实际展示过期版本、代码哈希或其匹配关系，才能把版本缓存从假设提升为事实；日志中的一般缓存命中、静态签名通过或递增版本后的单次成功都不足以单独确认根因。
