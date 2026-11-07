---
dev-loop: memory
format: v1
epic: on-device-residency
total-merged: 1
last-merge: 2026-11-07
state: maintenance
---

# on-device-residency

- [挂载] docs/design/on-device-residency.md

## 正文（终态提炼）

- **全批交付**（2026-11-07）：P0 观测面（TTL 参数化 + 六沿 Piggyback + JSONL 账本）/ P1 策略矩阵（ResidencyPolicy 单源 + scheduleTtl 接线 + 决策行）/ W6 双模全机制（SupplyTaskPool + 联合态 + status 拉取 + 顺风车排空 + 夜间批处理）。
- **真机验证**（PLQ110）：策略矩阵三档（缺省 5min / 灭屏 1min / 充电 30min）/ 冷态入池回执 / 顺风车消费（AI-CAP ms=7）/ WARM 直出（548 字）/ R4 首条数据点（45+ 装卸后碎片化疑似）。
- **新增门禁**：arch-guard R12（实现件 import 白名单）+ CI 镜像 + 注册语义 3 钉 + 回归锚 18。
- **关键定则**：①能力接口必须 implements 基接口（Dart is 晋升 S<:T）②测试单例语义 = flutter_test_config 进程注册 ③恢复逻辑随腿走不做跨腿装饰器 ④TTL 双源禁（scheduleTtl 读 effectiveTtlMs）⑤Pull = 交付真理源（freezer 吞 oneway）。
- **W6 消费端**：SDK OnDeviceOutcome.kt 已就绪（前轮立法预备）；§3.11.2 跨仓立法已推（goodshare 0702cc1）；plugin-core 解析面随 SDK 下一版发布。
- **R4 首条数据点**：~45+ 装卸后装载挂起 = CMA/ION 碎片化疑似（重启复测待做）。
- **遗留（非本 epic 债）**：低电/充电档需真实电源态验证；TRIM BACKGROUND 需高压场景；聚焦 loadModel 预热等 P0 数据；SDK plugin-core deferred 消费。
- 决策 D-1~D-7 全量：Ref: docs/design/on-device-residency.md「决策日志」。

## 断点
- [断点] 已完结：全批交付完毕：P0 观测面+P1 策略矩阵+W6 双模全机制；真机三档验证+端到端联调通过；R4 首条数据点+决策日志归档（docs/design/on-device-residency.md）——数据积累稳态期
