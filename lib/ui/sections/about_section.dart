/// 设置页 · 关于段（window-slim P1-A 分段拆解，2026-10-17 自 settings_page
/// 迁出）：版本号读取、检查更新入口、debug 联调入口全部自持。
///
/// 迁移语义原样保留（含测试锚点 Key）：
/// - 版本号只作展示，读不到按占位（不影响任何功能面），宁空勿炸；
/// - 检查更新是正式功能（release 也要能用），常驻可见不藏；
/// - 长按「关于」标题唤出 debug 联调菜单（`kDebugMode` 内自闸；release 长按
///   无响应），避免联调入口占据正式面。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../gateway_loop_debug_page.dart';
import '../tokens/console_tokens.dart';
import '../update_page.dart';

/// 段 widget：无外部依赖注入（版本号自读，入口导航自持）。
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection>
    with AutomaticKeepAliveClientMixin {
  /// ListView 懒构建会把滚出视口的 sliver child **销毁重建**——段内领域态
  /// （表单输入/错误态/探活结果）随之丢失（拆分前这些态在页面层，天然跨滚动
  /// 存活）。故段一律申请 keepAlive：拆段不得改变「滚动后回到面板仍是原样」
  /// 的用户可见语义。
  @override
  bool get wantKeepAlive => true;


  String _appVersion = '—'; // PackageInfo 不可用时占位（宁空勿炸）

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  /// 版本号独立初始化：失败按占位（ DEGRADE 留痕），不拖垮页面。
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = '${info.version}+${info.buildNumber}');
      }
    } on Object catch (e) {
      debugPrint('[DEGRADE] about-panel: 版本读取失败按占位: $e');
    }
  }

  /// debug 联调入口（2026-10-16 自聊天页 AppBar 迁入）：仅 debug 构建经长按
  /// 「关于」唤出，避免联调入口占据正式面。检查更新是正式功能，常驻可见不藏。
  Future<void> _openDebugMenu() async {
    if (!kDebugMode) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('网关/熔断联调'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const GatewayLoopDebugPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = consoleTokens(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 长按标题 = debug 联调入口（kDebugMode 内自闸；release 长按无响应）。
            GestureDetector(
              key: const Key('about-title'),
              onLongPress: _openDebugMenu,
              child: Text(
                '关于',
                style: const TextStyle(
                  fontSize: Fsz.sectionTitle,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'GoodHub $_appVersion',
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.telemetrySm,
                color: t.terminalMuted,
              ),
            ),
            if (kDebugMode)
              Text(
                '（debug 构建：长按「关于」进入联调入口）',
                style: TextStyle(fontSize: Fsz.microSm, color: t.terminalMuted),
              ),
            ListTile(
              key: const Key('about-check-update'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update_alt),
              title: const Text('检查更新'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const UpdatePage()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
