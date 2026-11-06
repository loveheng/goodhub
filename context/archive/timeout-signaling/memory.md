---
dev-loop: memory
format: v1
epic: timeout-signaling
total-merged: 1
last-merge: 2026-11-06
kind: temp
state: maintenance
---

# timeout-signaling（临时）

- [挂载] docs/design/timeout-signaling.md

## 正文（2026-11-06 归并自 devlog）

- W1-1 熔断 L2 解锁接 driverFingerprint：触发时同写指纹（`l2_lock_fingerprint` 第三键），锁期内比对，漂移=提前解锁清锁清指纹；任一侧拿不到=不比对保守不误开；遗留项=Build.FINGERPRINT 不含 QNN/Skel 版本（自更新换 AAR 不触发解锁，待 SDK 头文件接入）
- W1-2 探针让位状态机：onDeviceUserDemandGen 用户需求代次单件 + adapter byProbe 区分探针/用户路径；探针 load 前止步（isEngineBusy）、装载打断不记 EXCLUDED、微基准打断丢弃画像且跳 unload（模型转正给前台）；probeAdmission 既有 unawaited 零改动
- W2-3 装载进度事件+可取消（AIDL 零签名变更）：loadPhase 可观察 → chat_page 装载 pill 细分「解析资产/分配算力」；cancelLoadWait=请求侧脱钩（Future.any 三态 + kLoadDetached 哨兵），禁作废 _loadGen（cancel=detach 后台装载继续）
- W3-4 LivenessTick 信令下沉：AIDL 新增 oneway onLivenessTick()；:engine 受理瞬间 2s 周期 tick 刷 lastTokenAtMs（token 帧即最硬活体，2s 内有 token 则 tick 静默）；引擎 _onLivenessTick 重置全部活跃流看门狗（防首字前 30s 误判切云）；30s 兜底看门狗不撤（进程冻结 tick 同样不可达）；零跨仓契约变更（宿主内部 listener 面）
- 门禁态：analyze 0 issue；test/llm/ 345 绿 + 装载进度 4 例 + 熔断指纹 5 例 + 探针让位 4 例；真机 PLQ110 安装冒烟 APP_ALIVE 无 FATAL（2026-11-06）
- 收尾遗留（2026-11-06）：W1-W3 真机功能复测 / W4 跨仓终帧 / W5 上游 keepalive / driverFingerprint 盲区 → 转全局 context/todos.md；本 epic 临时归档终态，不 reopen

## 断点
- [断点] 已完结：W1-W3 全量落地（analyze 0 issue / 1776 测试绿 / 真机 PLQ110 安装冒烟过）；W4 跨仓契约、W5 待上游、真机功能复测与指纹盲区转全局待办
