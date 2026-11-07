---
dev-loop: devlog
format: v1
epic: on-device-residency
total-merged: 1
last-merge: 2026-11-07
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

（2026-11-07 P0 施工稿定稿 2 条已于同日归并入 memory.md 正文——细节见 docs/design/on-device-residency.md 第八节）
- [2026-11-07] [变更]: S-R0-a/b/c 三批施工完成：a) TTL 参数化（AIDL Bundle 缝 residencyTtlMs → EngineLifecycle.updateTtlMs + scheduleTtl 读 effectiveTtlMs——首版双源缺陷【调度侧直读 DEFAULT】真机时序暴露后修复，lessons 已记）；b) Piggyback 观测面（:engine 驱逐沿环境快照 + post-evict RSS 一次性双枪；Dart JSONL 账本 KeyedWriteQueue 整本原子写 + 滚动截半 + logcat 镜像；binding 三沿 load_ready/evicted/process_died；两腿 send 打点）；c) 电池白名单独立入口核验 = on_device_config_section 已有完整状态/申请行 + 独立测试（既有达成，零改动）；全量零行为变化验证（缺省不下发）
- [2026-11-07] [验证]: flutter analyze 0 issues；flutter test 全量 1808 绿（policy/metrics 新增 5 例；首跑 1 例偶发未再现未定级，复跑追踪）；arch-guard/docs-lint 通过；真机三线命中（ttl-configured 30000ms / evict 快照 batt=89 chg=false ps=false screen=true / rss-sample post-evict-5s/30s vmRss≈154MB 稳定）+ Dart 沿（load_ready/send/evicted）+ TTL 30s 时序（双源缺陷修复后）
- [2026-11-07] [变更]: 自动采样会话：harness 20 轮（调试历经 logcat 轮转断发现→pkill 自匹配自杀链→计数多行污染→锁自匹配四坑后收敛为凭据缓存直连 curl + 计数等wait + PID 文件锁）；样本档 + 采样器归档 context/epics/on-device-residency/samples/；【数据点】~45+ 装卸后 query_on_device 挂起（>90s 无装载完成）= CMA/ION 碎片化疑似，R4 观测面首条真机数据点，重启回收后复测对照待办
- [2026-11-07] [验证]: 真机采样会话执行（PLQ110）：~45+ 装卸循环、10+ 完整遥测周期、screen/chg 字段真实变化捕获；发现 R4 级信号（重复装卸后装载挂起）已入证据档
- [2026-11-07] [变更]: P1 施工稿定稿并落文档第九节（P1-a 驻留策略单源+TTL 矩阵 / P1-b TRIM 分档 / P1-c 水位单源 deviceProbe 携带 / P1-d 聚焦 bind 预热）——L1/L2 机制化，不翻任何现有拍板
- [2026-11-07] [验证]: docs-lint 通过；矩阵值与现状锚点经本轮取证核对（TRIM 即逐现状 EngineLifecycle.kt:116/MemGate 本地常量:17-25/warmup 双调用点/fg 流 :634）
- [2026-11-07] [变更]: P1 四批施工完成：a) ResidencyPolicy 单源（TTL 矩阵短路序 + TRIM 分档 + 常量唯一出处）+ scheduleTtl 接线（决策行 [RESIDENCY] policy 落账）+ fg 回填 lastCaller；b) TRIM 分档（CRITICAL/COMPLETE 才逐，BACKGROUND 降档 Defer + streak 超限升级）；c) 水位单 owner 降档为配对互指+观测对账（MemGate 装载闸与 :engine 护栏语义不同层，跨进程强统一单源评估否决——cargo-cult 规避，rationale 入 epic devlog）；d) 聚焦 bind 预热（composer 首聚焦去重 → warmupTouch → warmup 原语，不触权重装载）；真机验证缺口如实登记：低电/充电档需真实电源态（矩阵同函数覆盖）、TRIM BACKGROUND 需真机高压场景、P1-d 焦点去重靠 analyze+组件测试
- [2026-11-07] [验证]: flutter analyze 0 issues；flutter test 全量 1808 绿；真机矩阵双档命中：screen=true→ttl=300000ms（缺省档，caller 双沿 hostBackground/hostForeground 分类正确）+ screen=false→ttl=60000ms（灭屏档）；显式覆盖优先级前轮已证（30000ms override 压过矩阵）
- [2026-11-07] [变更]: W6-a/b 施工交付：SupplyTaskPool（JSONL 账本/状态机六态/M4 配额 per-caller 8 + 全局 64/M5 身份过滤/M6 毒丸死信 retries≥3/崩溃恢复 running→queued/滚动截半）；executor 联合态（allow_deferred 缺省 false 存量零变化 + OnDevicePrimitiveException catch 入池分支 + M5 无身份不受理）；HostSupplyTaskStatusExecutor（Pull 即交付真理源 + M5 过滤 not_found）+ Allowlist 登记（4 条）+ invoker 双工具分派；W6-b 顺风车排空（OnDeviceAdmin.drainSupplyPool ≤3 条 + K11 requeue 回池 + chat_send_use_case run finally 钩子 unawaited）；跨仓移交件（§3.11.2 修订文本）落文档 10.3 待用户写入 goodshare 仓
- [2026-11-07] [验证]: flutter analyze 0 issues；flutter test 全量 1816 绿（W6 新增 8 例 + gateway mount 断言 3→4 修订 + host_tool schema 单源断言双条目修订）；docs-lint 通过
