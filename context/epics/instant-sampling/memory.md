dev-loop: memory
format: v1
epic: instant-sampling
total-merged: 0
---

# instant-sampling · 即时 AI 摘要（goodhub 半边 = T3 分池）

- [定位] 主仓 = goodshare（设计稿 `docs/design/instant-ai-sampling.md` SSOT，epic 同建于该仓）；本仓半边 = MCP sampling 接缝的 pool 配额分池（goodshare ↔ goodhub 契约 ai-app-split.md §3.11 增量，2026-10-17 回写）
- [范围] 只动配额记账：`lib/mcp/sampling.dart`（SamplingQuota caps + handler pool 透传）+ 单测 + index.md 备注。协议语义/引擎/围栏/临时会话零改动
- [红线] sampling 模块零业务名词零场景分支：pool 只是配额 key 后缀（caps 白名单档位名 = 协议标识符，同字段名）；二期 goodshare 扩即时标签/模板时本仓零改动
- [施工硬化] pool 是 server 传入不可信值——caps 白名单判定内移 tryConsume 单点（未登记 pool 归默认池与 serverKey 共享额度，防伪造池名每名一池绕过限额）；-32000 消息去掉具体次数（分池超限时默认池上限数字会误导）
- [断点] T3 已完成（2026-10-17）：analyze 0 + sampling_test 14 绿 + 全量 773 绿；待 goodshare 侧 T5 真机联调（本仓半边就绪）
