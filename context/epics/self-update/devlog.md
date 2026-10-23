---
dev-loop: devlog
format: v1
epic: self-update
total-merged: 1
last-merge: 2026-10-14
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

- [变更] 2026-10-14 串包防御对齐 shiguang 方案（commit cbd0ecb 同款）：UpdateManifest 增 applicationId 可空字段；update_service.check() 拉到清单后比对本机包名（package_info_plus），不一致抛 UpdateException 拒更；update_page._install() 安装前二次比对（纵深防御）；release-r2.sh 从 android/app/build.gradle.kts 提取 applicationId 写入清单；新增 test/update/update_manifest_test.dart（2 例）；docs/design/self-update.md 清单格式/客户端表/安全纪律同步
- [变更] 2026-10-14 .env REMOTE_PREFIX 由 updates 收敛为 updates/goodhub（.env.example 同步），与 shiguang 的 updates/shiguang 各占子目录，根治共用桶根目录的覆盖（重）与串包（串）
- [2026-10-14] [验证]: 未执行: 专项清理（2026-10-19）补记——该轮验证账本历史缺失，无法回溯实证；后续触及 update_service 须补 analyze/test 自证
- [2026-10-14] [验证]: 未执行: 专项清理（2026-10-19）补记——纯配置路径收敛（.env / .env.example），无代码逻辑变更；后续触及发布链须以 release-r2 --json 预检自证
- [变更] 2026-10-24 发布 v1.1.2+2012 到 R2（bump→--json 预检→dry-run→--commit 全链通过）：线上清单 versionCode=2012、apkUrl=updates/goodhub/app-release-2012.apk，sha256 与本地构建一致（98290f56…）；changelog 经 .env CHANGELOG 注入，同时清掉遗留的 v1.0.2 旧值（2011 清单被其污染）
- [变更] 2026-10-24 release-r2.sh 旧 APK 清理键名修正：OLD_APK_KEY 改为完整对象键（公开域 URL 去域前缀，含 REMOTE_PREFIX；非本公开域 apkUrl 放弃清理），守卫比对同步改全键——upload-r2.mjs delete 按传入键原样签名，旧实现传前缀相对键名，DELETE 打到桶根不存在的键、S3 幂等返回成功致"删旧留新"上线以来静默失效；存量孤儿 updates/goodhub/app-release-2011.apk 已按修后语义补删（公网 404 实证），旧前缀 2002 残留（updates/app-release.apk + updates/goodhub-update.json）维持既有登记处置不动
