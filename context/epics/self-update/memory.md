---
dev-loop: memory
format: v1
epic: self-update
total-merged: 2
last-merge: 2026-11-07
---

# self-update

- [挂载] docs/design/self-update.md

## 结论与决策

- [结论] 2026-10-14 self-update 立项与整包自更新落地（SU1-3 已确认）：发布侧移植 scripts/release-r2.sh + upload-r2.mjs（R2 SigV4 零依赖直传，清单 goodhub-update.json）+ .env.example；客户端移植 lib/update/ 三件套（manifest / service 流式 sha256 校验 / installer open_filex）+ lib/ui/update_page.dart（检查/下载/安装三态）；入口 = chat_page ⚙ 调试菜单「检查更新」；新增依赖 crypto + package_info_plus(^9.0.1，10.x 与 flutter_secure_storage win32 互斥) + open_filex；Manifest 加 REQUEST_INSTALL_PACKAGES
- [结论] 首发 v1.0.0+2002 推 R2 成功：release-r2.sh 被 analyze 存量 info 阻断问题修复（降为 WARN 不阻断）；产物 goodhub-update.json + app-release.apk（42.7MB）公网可达
- [结论] 调试入口按构建形态拆分：AppBar 按钮全构建保留（debug=虫子图标/调试入口，release=更新图标/检查更新）；菜单内服务大厅/网关联调/M1 任务循环三项加 kDebugMode 门禁；检查更新为正式功能全构建保留
  - **2026-10-16 修正（入口位置变迁）**：聊天页 AppBar 已**不再保留任何按钮**——⚙ 设置移到侧边栏唯一入口；debug 入口收进设置页「关于」段：检查更新**常驻可见**（正式功能，全构建），网关联调 / M1 任务循环经**长按「关于」标题**唤出（kDebugMode 内自闸）。结论主体（构建形态门禁口径）不变，只是落点迁移
- 2026-10-14 串包防御对齐 shiguang 方案（commit cbd0ecb 同款）：UpdateManifest 增 applicationId 可空字段 + update_service.check() 拉清单后比对本机包名（package_info_plus）不一致抛 UpdateException 拒更 + update_page._install() 安装前二次比对（纵深防御）；release-r2.sh 从 build.gradle.kts 提取 applicationId 写入清单；测试钉 test/update/update_manifest_test.dart 2 例；设计稿同步。同日 .env REMOTE_PREFIX `updates`→`updates/goodhub`（与 shiguang 的 updates/shiguang 各占子目录，根治共用桶根目录的覆盖与串包）——纯配置路径收敛，无代码逻辑变更；该轮验证账本历史缺失已补记「未执行」，机械规则=后续触及 update_service 补 analyze/test 自证、触及发布链以 release-r2 --json 预检自证
- [结论] 聊天输入区桌面端美化：Center+ConstrainedBox maxWidth 720 限宽居中；输入框圆角(24)填充无边框 + contentPadding 16/10；发送按钮改圆形 IconButton.filledTonal（arrow_upward）；textInputAction newline 桌面 Enter 语义修正
- [结论] 云端模型多配置生效位：ByokStore 增 preferredProfileId 持久化（save 清理孤儿生效位）；hybrid_assembly 优先取生效 profile（未选回退首位）；服务大厅置顶同步写生效位；聊天页 ⚙ 设置加「云端模型(生效)」单选区（点选即切换，下个 Run 装配生效）——**2026-10-16 修正**：该单选区随 ⚙ 弹层并入设置页并删除（BYOK 面板已能切生效位，属重复入口）；生效位机制本身（preferredProfileId / hybrid_assembly 取生效）不变
- [结论] 2026-10-14 串包防御对齐 shiguang（commit cbd0ecb 同款思路，本仓落地）：UpdateManifest 增 applicationId 可空字段（旧清单宽容跳过）；update_service.check() 拉清单后比对本机包名（package_info_plus），不一致抛 UpdateException 拒更；update_page._install() 安装前二次比对（纵深防御）；release-r2.sh 从 build.gradle.kts 提取 applicationId 写入清单；.env REMOTE_PREFIX 收敛 updates/goodhub（与 shiguang 的 updates/shiguang 各占子目录）；新增 test/update/update_manifest_test.dart 2 例；release-r2.sh --commit 因 updates/ 被 gitignore 改用 git add -f

## 近期验证状态

- flutter analyze 0 新增（存量 1 info 不变）；flutter test --timeout 60s 446 例全绿；release-r2.sh 实跑 exit 0，v1.0.1+2003 已推 updates/goodhub/（清单带 applicationId=com.zzh.goodhub），公网 GET 200 且远端 APK sha256 与清单一致
- 残留风险（未处理）：桶根目录旧对象 updates/app-release.apk + 两份旧清单（goodhub 2002 / shiguang 28019）仍在，旧源客户端按 sha256 失配 fail-closed；upload-r2.mjs 无删除能力，建议后续补 delete 或后台手工清理

  - **2026-11-07 真机验证轮 + R2 重发收口（全链闭环日）**：①装机 release 4016 走真实 R2 源判「已是最新」——split 口径自洽（发布链清单 versionCode=APK 真身，发布渠道设备与清单同口径）；②R2 重新发版 v1.2.1（99a5d90）：4015 坏态（拆分泄漏+APK 404）根治，过程中抓到第二次事故——release-r2.sh `grep -m1 'applicationId'` 命中 bench 注释行污染清单，根治=提取锚定行首赋值 + 包名格式防呆守卫（非法即 FATAL），lesson 已落 inbox；③UpdateService 增可注入 httpTimeout（默认 30s）覆盖 TCP/响应头/响应体无推进三挂起点（真机 404 流永挂根因=dart:io 零超时），4 回归钉 + 全量 1803 绿，代码随 1d999f9 入库；④安装器落地实测：授「安装未知应用」后全链闭环（发现 4017→下载→SHA-256→确认卡→系统安装器→应用已更新→重启），同码覆装驱动口径（--build-number 基线+清单声明触发，release 不可降级/-d 被拒/卸载清数据三路皆否）；⑤小缺口留观察：陈旧「需要权限」弹卡在授权+重启后复现（失败态快照不自愈）。驱动坑：debug 桥树 bounds 会随布局差异错位，tap_bounds 失败用截图换算兜底。

## 断点
- [断点] 下一步：self-update 全部收口：①安装器落地实测 ✅ ②404 下载流收口 ✅（代码随 1d999f9 入库）③4016 口径观察 ✅ 自洽成立 ④账本已提交 4407208；无待办——仅陈旧权限弹卡不自愈小缺口留观察（下次触及更新页顺带核），新需求待用户指令
