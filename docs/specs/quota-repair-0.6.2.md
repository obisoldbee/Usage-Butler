# 0.6.2 额度修复范围

用户要求对两项已有P2先补生产路径测试复现，再做最小修复；使用所提供的Grok原始SVG，名称统一显示Grok；删除OpenAI和MiniMax人工“来源读数”详情及Grok共享周额度灰色标题，保留真实明细。设置底部通用关闭说明与Grok专属权限说明应各归其位。

GROK-01为旧关闭操作在缓存清理等待期间，被新开启操作超越后取消新刷新计划。测试使用生产ProviderController和RefreshScheduler，控制缓存暂停、时钟与实际回调，覆盖自动刷新、刷新重试、发现重试及正常关闭、仅手动和shutdown。修复按代际核对与已捕获token取消，保留新计划。

QDM-01为精确Decimal百分比提前转换Double，使接近100%的显示取整及30/60颜色边界丢失。测试从未加引号的JSON数字经生产解码、Domain、reducer、mapper到UI显示和颜色函数。精确usedCents为9999.9999999999999999、6999.9999999999999999及3999.9999999999999999，预算10000，另覆盖准确30/60、0/100及正不足1。展示、颜色与方向遵循[额度展示合同](quota-display-mode.md)。

原始Grok SVG位于Resources/Artwork/grok.svg；原生WebKit栅格化后等比例缩小为资产，保留原色和图案。内部Provider标识、偏好键、缓存身份和认证协议保持兼容。通知文案同步使用Grok。

用户要求核实OpenAI Credits有无到期等字段，没有则保持。当前官方CreditsSnapshot仅含hasCredits、unlimited、balance，重置权益为独立数据。用户另要求研究MiniMax新查询方式与内容，本版不新增认证渠道或套餐转换。现有mmx quota仍为推荐入口，视频周额度已经进入Domain但当前投影隐藏；新M Plan与旧Token Plan的周期及权益需按真实返回区分。

集成验证覆盖受影响的Controller/Scheduler、Provider和缓存、Decimal显示、真实详情、图标及告警。离线产品框架渲染使用合成输入；正式安装、后台注销恢复、同签名升级、持久历史保留分别核验。完整测试、VoiceOver/物理键盘、macOS13/Intel实机与长期运行只在实际执行后报告。
