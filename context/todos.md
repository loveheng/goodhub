---
memo: todos
format: v2
---

# 待办列表

## misc
- [ ] [2026-10-16] (风险) [long] HEAD 存量测试失败移交：memory_kernel_test 2 例（session 域路由 wsStates upsert 断言 'dark' 得 null / undo 回滚残留 ui.lang），本轮四边改造未触碰 memory_kernel/workspace_state_store（git log 佐证），疑与并发窗口 memory_governor_test 失败同族；收敛条件：chatmessage/memory 域窗口下轮跑 test/coordinator/memory_kernel_test.dart 定位根因修复 (src: ai, arch-hardening 验收移交)
- [ ] [2026-10-16] (风险) (层:L2) (重:轻) ux-hardening 归档转办·6 处 DEGRADE 标记清算台账（均为有意降级且已补用户可见/收紧方向，不删标，逐条留痕）：① hybrid_cloud_engine.dart:59 探测失败视作在线（朝向更丰富路径，其失败经 P0-2 错误卡可见）；② hybrid_cloud_engine.dart:77 门禁探测异常 fail-closed 关闸（P2-1 已收紧，原放行方向偏危险）；③ cow_sync.dart:74 覆写损坏→先备份再空库起步（P2-1 ③，corruptBackupPath 供面板警示+人工找回）；④ conversation_archive.dart:122 配额损坏/签名不符→备份后按无记录（P2-1 ④，lastQuotaError 轨道通告不再静默清零）；⑤ hybrid_assembly.dart:64 BYOK 读取失败→端侧路径 + note 上轨告知（P2-1 ①）；⑥ conversation_store rename 站点（P1-5：原子重写缺失/损坏返 false 不抛穿，UI toast 反馈）——收敛条件：出现真实用户受损案例或兜底方向需再裁决时复核 (src: ai, ux-hardening ::done 标记结算)
- [ ] [2026-10-16] (功能) (层:L4) (重:中) 更新页安装失败提示「去系统设置允许安装未知应用」但无跳转：需 ACTION_MANAGE_UNKNOWN_APP_SOURCES 平台通道（或 app_settings 依赖——新依赖须先确认）；当前仅文案提示，用户须自己找系统设置 (src: ai, ux-hardening P0-3 收尾)
- [ ] [2026-10-16] (风险) (层:L1) (重:中) 本地插件发现通道（goodhub/binder_mcp discover）无响应时 chat_page _loadEndpoints 无限挂起：MethodChannel.invokeMethod 无超时，抛异常有 catch 兜底、挂起没有——宿主 Binder 服务假死（不崩也不回）时端点缓存/默认绑定/网关同步/引导卡全部不初始化，页面表现=永久空态无报错。收敛方向：scan() 或 _loadEndpoints 加超时兜底（超时按空目录继续） (src: ai, ux-hardening P0-1 实施发现)
- [ ] [2026-10-16] (清理) [long] [::done 审计移交] window-kernel-split 收尾时 ctx-audit 出 17 违规 20 告警，其中本 epic 项已全部修复（归并/验证格式/todos 回收/归档）；**跨 epic 存量未动**：ai-app-split 骨架损坏+头部缺 YAML、init/m2-5/m3-ui 缺断点章节、m4/page-revamp/system-assessment/thirdconnect devlog 待归并（11/14/20/20 条）、page-revamp 未归并 [SSOT 修正]、多处 todos 头部与格式违规、RECLAIM 打勾待回收（m4×4/system-assessment×13/thirdconnect×11）、MOUNT 挂载失效×4。建议按 epic 分批 @audit 修复 (src: agent, ctx-audit)
- [ ] [2026-10-16] (文档) [long] `coding-standards.md` §2 规则 2 仍按 SessionManager 存在编写(主 Isolate 的 SessionManager 状态机 + Trace-ID 亲和穿透),但 SessionManager 仲裁已显式关闭(architecture §15)、无具名类,且 window-kernel-split 已立 ConversationSession 承接会话态 → 规范与现状及新设计双错,后续会去实现不存在的组件。收敛条件:会话态落点确定(步 0/步 3)后回改 §2 规则 2——写明 SessionManager 已关闭、Trace-ID 亲和穿透的真实归属(现仅 gateway_loop_guard 做入站环阻断 -32000),并同步 architecture §15。跨域(规范 + architecture),不属 window-kernel-split 域内 (src: ai, window-kernel-split 评估)

- [ ] [2026-10-13] (清理) [short] 存量 analyze info：lib/ui/gateway_loop_debug_page.dart:670 deprecated_member_use（'value'→'initialValue'，Flutter 3.33 弃用）——行号自 :635 漂移（2026-10-15 对账修正）；非 M4 范围，散修轮顺手清 (src: agent)
- [ ] [2026-10-11] (测试) [short] T5 拦截卡三态真机验证（M2-T7 余量）：goodhub 盾牌页开「遮蔽失败注入」→ 出 Amber 卡 → 「取消」=轨道✕请求未外发；再跑点「明文发送一次」=请求真外发。fail-closed 态单测已盖 (src: agent)
- [ ] [2026-10-11] (风险) [long] architecture §16 门槛校准待拍板（M2-T7 余量）：现网包实为 qwen25-1.5b-Q8（1.49GB 文件）全载增量 ~1.9GB/峰值 PSS 2.70GB——a) 可用门槛起调 ≥3.5GB（Q8 口径）b) 换发 INT4 包（内存减半，维持 2.5GB）c) 双档按设备选包（M3）。定案前 Q8 维持现网 (src: agent, T7 实测)
- [ ] [2026-10-10] (风险) [long] (暂缓) 反向 Server 角色（:8766 对外暴露特权工具）暂缓不做；服务对象=桌面 AI 平台（MCP 客户端）；若重启走「桌面平台先记录待完成 → 宿主批量处理」形态（FC6），非实时直调——触发条件：出现第一个桌面平台需宿主做事的真实场景 (src: 用户, 裁决)
- [ ] [2026-10-11] (风险) [long] goodshare MCP server 监听与 activity 生命周期耦合（T7 机制定案）：后台 stopped 态保活 16min+ 无恙；死因唯一=activity 销毁（BACK/系统清任务连带走 Dart VM），am start 可能复用残态 activity 不恢复——恢复唯一可靠路径=force-stop 冷启动或划掉任务卡；处置=不改 goodshare 代码，联调起手式=核对开关+listening+冷启动，M3 真实场景高频复现再评估跨仓硬化 (src: agent, T4c+T7 实测定案)

- [ ] [2026-10-16] (风险) [long] **零 DI / 零路由 → 三处拼装已产出生产 bug**：`main.dart:97-115` 直挂 `home: const ChatPage()`，无 DI 容器与路由表 → `mcp_servers.json` 被拼 3 处（`chat_page:303` / `settings_page:270` 均传 `prefs`，`gateway_controller:148` **漏 `prefs`** → 旧单端点 SharedPreferences 在网关侧读不到 = 已存在的行为不一致，非单纯重复代码）。**收敛条件**：随 window-kernel-split 步 0 的 `ServiceDirectory` 单一入口**同轮**建立装配容器，不额外立项 (src: agent, 全局迁就设计审视)
- [ ] [2026-10-16] (风险) [long] **三项已锁定设计缺解冻触发条件**：① D-C 单一私有槽位（`host-gateway-accessibility-memory.md:278`）✅锁定但**无解冻条件**；② D-E In-band 记忆提取（同文件 §3.1 / D-E；真实理由 = **0 额外前缀 Token + 缓存断点 A 保护 + 因果一致**，**非**「端侧不可用」——端侧 SLM 已真机实证且在摘要化路径中使用）✅锁定但**无解冻条件**；③ `window-kernel-split.md` §9 不做常驻连接池仅写「依赖未做的 G8」，缺 TTFT 量化阈值。**收敛条件**：逐条补触发条件；②与既有 FC1（记忆 >500 条或注入占比 >30% 持续一周 → SQLite-vec/ObjectBox）**合并去重，以 FC1 阈值为准**，勿另立更粗的阈值 (src: agent, 全局迁就设计审视)
- [ ] [2026-10-16] (风险) [long] **SSOT 反向改写纪律**：CM1（`pending-confirm.md:23`）§9.5 SSOT 定 SQLite → 实现以「零新依赖、MemoryStore 同栈」改文件型 KV → **回填修改 SSOT**。SSOT 由「设计源」退化为「实现记录者」，日后迁 sqlite 成本更高。**收敛条件**：确立「实现偏离 SSOT 须**先改 SSOT 再改实现**，且须记偏离理由与回迁条件」；新偏离一律走 pending-confirm 台账。存量 CM1 不翻案，但补记回迁触发条件 (src: agent, 全局迁就设计审视)

- [ ] [2026-10-16] (风险) [long] [window-kernel-split 移交·Archive epic] 铁律 2 降级后窗口间不共享可变引用无静态兜底：收敛条件=补窗口层 import 白名单断言（lint 或测试），或明确接受人工审视 (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] [window-kernel-split 移交] RuntimeDelegates 8 端口聚合类打包传入不可部分替换：端口数涨到 10+ 时回设计稿复议边界（可能误搬了执行期事件），不得静默加字段 (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] [window-kernel-split 移交] 内核↔内核具体类型直连无注入位（hybrid_assembly.dart:36 硬 new ByokStore()）：出现第二个 Directory/Memory 实现需求时再抽 abstract interface class（现裁决=接口爆炸收益低） (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] [window-kernel-split 移交] 事件循环（chat_page 991-1105）留窗口含两处写内核态（transcript 回写/绑定捕获）：写回收口需重开裁决（代价=执行期事件流进内核） (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] [window-kernel-split 移交] ServiceDirectory 变更通知通道（场景暂不成立）：若跨页一致性出问题，用纯 Dart revision 计数比对，不引 ChangeNotifier/事件总线 (src: agent, 二轮评估)
- [ ] [2026-10-16] (注意) ctx-audit 存量账（16 违规 19 告警，均在 m4/page-revamp/chatmessage/thirdconnect/self-update/system-assessment/m3-ui-subs-sampling/m2-5-skill-refstore）：各 epic devlog 归并（≥5 条）+ todos 头部格式（memo-collector §0）+ 挂载失效修复——随各 epic 恢复窗口处理，多窗口活跃期严禁代归并（防脑裂） (src: agent, archive-memory-claim ::done 审计移交)
- [ ] [2026-10-16] (注意) archive-memory-claim 真机冒烟（归档挂起项）：Archive 新建/切换/删除/恢复/损坏五路径 + 配额杀进程保留 + 记忆胶囊/撤销 + 外提视图件（菜单/抽屉/状态带）回归——待用户侧载 (src: agent, archive-memory-claim 收尾)
