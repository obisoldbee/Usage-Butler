# 网络主面板与按应用观察边界（0.3.5）

2026-09-23；观察与方案分开。界面调整已实现，下面的系统扩展路线仍待开发和实机验证。

## 本轮界面约定

正常主面板直接呈现五档范围、上传和下载趋势。采集状态/开关、自动/手动统计对象、能力说明及采样诊断集中到“设置 → 网络”；只保留顶栏统一设置齿轮。主面板保留非健康采集与当前范围的历史重新起算提示，停止/过期/未知不显示为实时零。选择接口只改变观察对象，不修改网络连接；保留现有偏好。Debug显式演示继续标记来源，Release不出现模拟应用。

## Observed：现有实现

`GetifaddrsInterfaceCountersReader`实际通过公开IFMIB读取接口计数；`NetworkCollector`据此结算接口速率和有界历史。真实来源没有应用归属、连接端点或规则执行；`project.yml`没有NetworkExtension/SystemExtension target，`Config/UsageButler.entitlements`为空。当前ad-hoc构建不是可部署网络扩展的签名证明。“按应用尚未接入”不能通过用户设置开启。

## Proposed：接入顺序

1. 建立macOS内容过滤System Extension的最小可部署验证，接收真实flow，初始全部允许。Apple将macOS内容过滤provider的部署形式列为System Extension，支持Developer ID直接分发；不用把iOS的受监督设备限制套用到Mac。[TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
2. 配置宿主与扩展的签名、标识、相应entitlement/provisioning、安装/激活与系统授权反馈。Developer ID分发需要对应Network Extension profile；当前账户/证书资格未检查。不得以关闭SIP、加root权限或当前ad-hoc签名冒充正式接入。[Network Extensions Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
3. 通过flow的应用/进程audit token建立稳定身份，处理helper进程、退出及身份未知；按应用聚合真实统计再接现有Domain/Core合同。[sourceAppAuditToken](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappaudittoken)
4. 请求统计报告，用单调时间、flow身份/序号和有界队列结算上下行。API提供statistics回报频率，但仍须验证目标OS的实际字段语义、累计/增量、关闭时最后报告及重复/丢失；不能直接把每次报告相加。Apple字节属性页仅描述flowClosed，而statistics事件/频率页描述持续回报，此处列为实测门，不因文档有字段就宣称秒级流量可用。[statisticsReportFrequency](https://developer.apple.com/documentation/networkextension/nefilternewflowverdict/statisticsreportfrequency)、[bytesInboundCount](https://developer.apple.com/documentation/networkextension/nefilterreport/bytesinboundcount)
5. 显示实际端点；只有系统提供域名时才展示域名。remoteHostname仅适用于由按名称创建连接API产生的部分flow，缺失时保持IP/未知，不将反向DNS当成实际访问域名。[remoteHostname](https://developer.apple.com/documentation/networkextension/nefiltersocketflow/remotehostname)
6. 先交付观察，再单独实现连接防护：验证新连接与已有连接差异、规则版本/执行回执、授权撤销、失败和卸载恢复。观察功能可用不代表阻断已经生效。

验收至少包含长短连接、TCP/UDP、浏览器helper、VPN/物理口去重口径、睡眠/唤醒、扩展/宿主重启、拒绝授权、计数边界，以及有界缓存/历史和持续内存观察。没有相应真机收据的能力继续保持不可用。接口计数与flow字节统计口径不同，不承诺逐字节相等。

本轮没有安装系统扩展、请求新权限、读取开发者账户/私钥或执行阻断。用户提问仅用于明确工程缺口，尚未把后端方案视为已实现能力。
