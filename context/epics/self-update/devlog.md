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
