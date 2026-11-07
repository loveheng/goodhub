---
dev-loop: devlog
format: v1
epic: self-update
total-merged: 2
last-merge: 2026-11-07
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

（2026-10-14 全部条目已于 2026-11-07 归并入 memory.md——串包防御三件套 + REMOTE_PREFIX 子目录收敛；过程细节见 git 历史）
- [2026-11-07] [变更]: 真机自更新链验证轮（设备 Ace 6 在位，断点项执行）：①生产 R2 清单坏态取证——versionCode=4015 为拆分包泄漏（2015+2000，lessons splits 偏移坑）+ apkUrl app-release-2015.apk 已 404（release-r2 旧键清理后清单未同步重发），装机 2016 会被误判有更新且下载必败，待用户重新发版修复；②装机 v1.2.1 检查更新报「尚未配置更新源」——UPDATE_SOURCE_URL 编译期未注入，与页面文案「默认更新源已内置」不一致（源缺失属构建配置非代码缺陷）；③正路径全链实证（本地 HTTP 服务+adb reverse，绕 IME 输入缺陷走编译期注入）：发现新版本→下载流式落盘→SHA-256 校验通过→确认卡→「已拉起系统安装器」，最终被 ColorOS 未授「安装未知应用」权限拦截（系统闸门非链路缺陷，App 侧弹卡+去设置直达为设计路径）；④串包防御负路径实证：applicationId 不符清单被拒，文案报因精确（清单=com.zzh.shiguang 本机=com.zzh.goodhub）；⑤发现下载健壮性缺口：apkUrl 404 时下载卡 ~10% 不报错（statusCode!=200 检查在但 404 响应体流未及时失败，疑似 CDN 错误页流挂起），待复现收口；⑥驱动坑：debug 桥树 bounds 与实际布局错位（布局差异致坐标偏移），tap_bounds 失败时用截图换算 system-tap 兜底
- [2026-11-07] [验证]: 真机截图留证 build/su_*.png（check/pos/inst/final/confirm/sysinst/neg2 七态）+ 本地服务访问日志（manifest 200 ×2 + apk 下载完成）；flutter build apk --debug ×3 全绿 + adb install Success ×3；未执行 flutter test（本轮零代码改动，纯真机验证轮）；设备已恢复 clean 包（无注入源 v1.2.1 build 2016），测试服务与 reverse 已拆
- [2026-11-07] [变更]: R2 重新发版收口（用户授权 --commit）：①dry-run 预检 → --commit 发布 v1.2.1，APK app-release-2016.apk（29.8MB）上传成功（ETIMEDOUT 重试后 OK），旧 2015 包顺带清理，仓库清单随脚本提交 99a5d90；②发布后外网核验抓到新事故——清单 applicationId 被污染成 build.gradle.kts 注释行（release-r2.sh grep -m1 'applicationId' 命中 2026-11-04 bench 变体注释，串包防御会拒掉全部更新）；③根治两件：提取逻辑锚定行首赋值（'^\s*applicationId\s*='）+ 发布链新增清单字段防呆（APP_ID 非合法包名格式即 FATAL 中止，勿带病上传）；④本地清单修正后重传 R2，外网复核 applicationId 正确、APK 可达、sha256 一致——坏清单存活窗口约 20 分钟，无装机消费（装机 2016 整包在本轮验证期间未走检查更新）
- [2026-11-07] [验证]: 外网核验：清单 applicationId=com.zzh.goodhub ✅ + APK HTTP 200（29818218 字节）+ 远端 sha256 与本地产物一致（dd6c30ce…）；bash -n + 防呆守卫正反样本自测（注释行样本咬住/com.zzh.goodhub 放行）；未执行 flutter test（脚本与清单轮，无 Dart 改动）
- [2026-11-07] [变更]: 404 下载流不失败缺口收口（断点遗留②）：UpdateService 增可注入 httpTimeout（默认 30s，测试注入短值），覆盖三个挂起点——TCP 连接（connectionTimeout）/响应头等待（close().timeout）/响应体无推进看门狗（res.timeout 每 chunk 重置计时）；check() 与 downloadApk() 同族修复；真机形态（R2 对已删 APK 的 404 流挂起）由「响应头挂起永不回应」单测复现钉死；页面侧零改动——超时走既有 UpdateException 通道，红字报因可见
- [2026-11-07] [验证]: flutter analyze lib/update + test/update → No issues found；flutter test test/update/ → 22 全绿（含新增 4 钉：404 快速失败/响应头挂起超时/响应体半途 stall 超时/清单拉取超时）；flutter test --timeout 180s 全量 → 1803 全绿（0 破坏）
