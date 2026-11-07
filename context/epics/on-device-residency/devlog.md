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
