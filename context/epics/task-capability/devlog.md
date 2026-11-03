---
dev-loop: devlog
format: v1
epic: task-capability
total-merged: 2
last-merge: 2026-11-03
---
- [2026-11-03] [变更]: S14e 排除位与协作打断语义：① localOnly 排除位收口——发现双通道漂移风险（verdict.localOnlyViolation→LocalOnlyViolationException 既有单通道 vs 本轮新增的 requirement.localOnly 后置分支），裁决收口为 verdict.localOnlyViolation 单通道（覆盖声明不可满足类+端侧状态类全部落空段，快速失败不切云 K10），删除后置重复分支并钉「禁双通道漂移」注释；② 打断术语订正——hybrid_cloud_engine.dart 头部「抢占语义」改「打断语义（S14e，K11，术语订正）」：协作式打断非抢占、等待窗口耗尽不得假设打断已生效、按策略性降级处置（切云或显式上浮等待）、不得以重启引擎腾算力（引用 lessons.md engine-stream 实证行）；on_device_engine.dart / on_device_engine_aidl.dart 术语订正本轮取证确认已在场（此前窗口已落）；tool_router/discovery_executor 的「抢占槽位」是私有槽替换语义非算力打断，不改。回归钉 2 例：localOnly+端侧落空→LocalOnlyViolationException 且云端零调用、离线+localOnly 同口径。验证：hybrid 全套+判定链 109/109 + analyze 0 issue
- [2026-11-03] [验证]: flutter test test/coordinator/hybrid_*.dart test/coordinator/capability_router_test.dart → +109 All passed; flutter analyze lib/coordinator/ test/coordinator/ → No issues
- [2026-11-03] [变更]: S15 判据优先级与缺省回归（W2 收口件）：回归钉 5 例落 send() 级——①声明不可满足（needsTools=true）不被 preferOnDevice 拉回端侧（云端照走+端侧零调用）；②声明可满足时偏好生效（云端健康也走端侧）；③声明不可满足+localOnly+偏好 → LocalOnlyViolationException 显式失败（偏好不得覆盖声明也不切云，红线钉）；④降级链冷却态（连续两次 5xx → shouldUseCloud=false）不覆盖声明（冷却期 needsTools=true 云端照走）；⑤缺省零变化（无声明健康态走云端，推导声明等价旧判据）。画像>偏好优先级由 send() 查表门禁顺序保证（profileExcluded 独立第三门禁；AssetManager 进程单例不 mock，真机场次承接，判定链 admissionProfile 段已单测）。验证：hybrid+判定链+值对象 125/125 + analyze 0 issue
- [2026-11-03] [验证]: flutter test hybrid_*.dart capability_router_test.dart capability_requirement_test.dart → +125 All passed; flutter analyze lib/coordinator/ test/coordinator/ → No issues
