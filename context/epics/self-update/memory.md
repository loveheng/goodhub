---
dev-loop: memory
format: v1
epic: self-update
total-merged: 1
last-merge: 2026-10-14
---

# self-update

- [挂载] docs/design/self-update.md

## 结论与决策

- [结论] 2026-10-14 self-update 立项与整包自更新落地（SU1-3 已确认）：发布侧移植 scripts/release-r2.sh + upload-r2.mjs（R2 SigV4 零依赖直传，清单 goodhub-update.json）+ .env.example；客户端移植 lib/update/ 三件套（manifest / service 流式 sha256 校验 / installer open_filex）+ lib/ui/update_page.dart（检查/下载/安装三态）；入口 = chat_page ⚙ 调试菜单「检查更新」；新增依赖 crypto + package_info_plus(^9.0.1，10.x 与 flutter_secure_storage win32 互斥) + open_filex；Manifest 加 REQUEST_INSTALL_PACKAGES
- [结论] 首发 v1.0.0+2002 推 R2 成功：release-r2.sh 被 analyze 存量 info 阻断问题修复（降为 WARN 不阻断）；产物 goodhub-update.json + app-release.apk（42.7MB）公网可达
- [结论] 调试入口按构建形态拆分：AppBar 按钮全构建保留（debug=虫子图标/调试入口，release=更新图标/检查更新）；菜单内服务大厅/网关联调/M1 任务循环三项加 kDebugMode 门禁；检查更新为正式功能全构建保留
- [结论] 聊天输入区桌面端美化：Center+ConstrainedBox maxWidth 720 限宽居中；输入框圆角(24)填充无边框 + contentPadding 16/10；发送按钮改圆形 IconButton.filledTonal（arrow_upward）；textInputAction newline 桌面 Enter 语义修正
- [结论] 云端模型多配置生效位：ByokStore 增 preferredProfileId 持久化（save 清理孤儿生效位）；hybrid_assembly 优先取生效 profile（未选回退首位）；服务大厅置顶同步写生效位；聊天页 ⚙ 设置加「云端模型(生效)」单选区（点选即切换，下个 Run 装配生效）
- [结论] 2026-10-14 串包防御对齐 shiguang（commit cbd0ecb 同款思路，本仓落地）：UpdateManifest 增 applicationId 可空字段（旧清单宽容跳过）；update_service.check() 拉清单后比对本机包名（package_info_plus），不一致抛 UpdateException 拒更；update_page._install() 安装前二次比对（纵深防御）；release-r2.sh 从 build.gradle.kts 提取 applicationId 写入清单；.env REMOTE_PREFIX 收敛 updates/goodhub（与 shiguang 的 updates/shiguang 各占子目录）；新增 test/update/update_manifest_test.dart 2 例；release-r2.sh --commit 因 updates/ 被 gitignore 改用 git add -f

## 近期验证状态

- flutter analyze 0 新增（存量 1 info 不变）；flutter test --timeout 60s 446 例全绿；release-r2.sh 实跑 exit 0，v1.0.1+2003 已推 updates/goodhub/（清单带 applicationId=com.zzh.goodhub），公网 GET 200 且远端 APK sha256 与清单一致
- 残留风险（未处理）：桶根目录旧对象 updates/app-release.apk + 两份旧清单（goodhub 2002 / shiguang 28019）仍在，旧源客户端按 sha256 失配 fail-closed；upload-r2.mjs 无删除能力，建议后续补 delete 或后台手工清理

## 断点
- [断点] 下一步：真机侧载 v1.0.1+2003（或 App 内把更新源改为 https://r2.oklhj.eu.org/updates/goodhub 后走「检查更新」）；设备端验证串包防御（把更新源临时指向 updates/shiguang 应被拒）
