---
dev-loop: devlog
format: v1
epic: timeout-signaling
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-11-05] [变更]: docs/design/timeout-signaling.md 吸收 2026-11-05 评估修订：W1-1 补指纹零副作用口径+QNN 版本遗留项；W1-2 补首问空窗兜底（未知放行降级链）+探针单槽让路约束；W2-3 补 cancel=detach 语义（禁接 _loadGen 作废，互斥已由单飞+单装载覆盖）；W3-4 补信令形态（token 帧=活体证据，LivenessTick 周期下限 2s）；W4-5 措辞改'正常路径接管'+120s idle 兜底保留
- [2026-11-05] [验证]: toolbox run docs-lint → OK: docs/ 全部校验通过（提示 0 项）
- [2026-11-06] [变更]: W1 批次落地：①W1-1 熔断 L2 解锁接 driverFingerprint——触发时同写触发时指纹（SharedPreferences 第三键 l2_lock_fingerprint），isBroken 锁期内比对（漂移=提前解锁清锁清指纹；任一侧拿不到=不比对保守不误开），指纹走既有 deviceFingerprint 通道（Build.FINGERPRINT 系统属性直读零副作用，无死锁面）；遗留项=Build.FINGERPRINT 不含 QNN/Skel 版本（自更新换 AAR 不触发解锁，待 SDK 头文件接入）。②W1-2 探针让位状态机——onDeviceUserDemandGen 用户需求代次单件 + adapter byProbe 区分探针/用户路径（用户 enable/generateStream 入口 touch），探针 load 前止步（isEngineBusy=loadState loading）、装载打断不记 EXCLUDED、微基准打断丢弃画像且跳过 unload（模型转正给前台，禁驱逐用户正用会话）；probeAdmission 既有 unawaited 后台异步零改动
- [2026-11-06] [验证]: flutter analyze 0 issue + flutter test test/llm/ 345 绿（含熔断指纹解锁 5 例 + 探针让位 4 例）
- [2026-11-06] [变更]: W2-3 装载进度事件+可取消落地（AIDL 接缝零签名变更——onLoadPhaseChanged oneway 既有契约贯通，本轮纯 Dart 消费面）：①引擎 loadPhase 可观察（binding 接线→OnDeviceEnableCapable 接口上提→adapter 透传→chat_page 装载 pill 阶段细分文案「解析资产/分配算力」，装载收口复位-1）；②cancelLoadWait=请求侧脱钩（_awaitLoadTask Future.any 三态：task true=就绪/false=终态失败原语义上抛/_loadTaskError、kLoadDetached 哨兵=用户取消脱钩可重试退出），禁作废 _loadGen（cancel=detach，后台装载继续，B-2 语义不变）
- [2026-11-06] [验证]: flutter analyze 0 issue + flutter test test/llm/ 全绿（装载进度 2 例 + cancelLoadWait 2 例）+ toolbox run build-apk --install 真机 PLQ110 安装成功 + 启动冒烟 APP_ALIVE 无 FATAL
- [2026-11-06] [变更]: W3-4 LivenessTick 信令下沉落地：①AIDL listener 新增 oneway onLivenessTick()（纯新增无签名变更）；②:engine 受理瞬间启动 2s 周期 tick（startLivenessTick，首帧恒第 2s 覆盖 prefill 空档——用户微观约束#3），sink.flush() 刷 lastTokenAtMs（2s 内有 token 则 tick 静默——token 数据帧即最硬活体，禁重复心跳拖 IPC），finally stopLivenessTick 统一收口；③Bridge invokeOnMain 转发 + binding onLivenessTick 回调 + 引擎 _onLivenessTick 重置全部活跃流看门狗（防首字前 30s 误判切云）；看门狗 30s 兜底不撤除（进程冻结场景 tick 同样不可达）。接缝纪律判定：本轮零跨仓契约变更（loadModel/startGenerate/generationParams/MCP 工具族签名零动），变更全落宿主内部 :engine listener 面，goodshare ai-app-split.md 承载面=goodshare↔goodhub MCP 接缝（文档头部明载宿主内部设计不在其域）无需修改
- [2026-11-06] [验证]: gradlew :app:compileDebugKotlin exit 0 + flutter test on_device_load_progress_test 4 例全绿（含 tick 喂狗防误判钉）+ 真机安装冒烟 APP_ALIVE
