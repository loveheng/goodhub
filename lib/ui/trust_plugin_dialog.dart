/// 本地插件信任卡片（thirdconnect §1.2.6）。
///
/// 第三方（非同签名）本地插件首次接入时弹确认卡，展示包名与签名 SHA-256 指纹；
/// 确认后持久化入白名单（[TrustedPlugins]）。抽取为独立可复用 widget，便于
/// integration_test 直接驱动真实卡片路径（原 chat_page 内联实现上移至此）。
library;

import 'package:flutter/material.dart';

import '../mcp/local_plugin_discovery.dart';
import '../mcp/trusted_plugins.dart';
import 'tokens/console_tokens.dart';

/// 信任卡片 UI（纯展示 + 两个回调）。标题/包名/SHA-256/「信任并挂载」均带固定文案
/// 与 monospace 指纹，便于测试按文本断言。
///
/// **按钮权重（ux-hardening P1-8）**：安全 UI 惯例——危险/不可逆选项走弱化
/// 路径。「信任并挂载」= OutlinedButton（弱化），「拒绝」= FilledButton（安全
/// 默认、视觉主位）。历史病：两者权重反置（信任=高亮主按钮），诱导用户授权。
class TrustPluginDialog extends StatelessWidget {
  const TrustPluginDialog({
    super.key,
    required this.info,
    required this.onConfirm,
    required this.onDeny,
  });

  final LocalPluginInfo info;
  final VoidCallback onConfirm;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return AlertDialog(
      title: const Text('信任本地插件？'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('发现未与 GoodHub 同签名的本地 MCP 插件：'),
            const SizedBox(height: 8),
            Text(
              '名称：${info.serverTitle}（${info.serverId}）',
              style: TextStyle(fontFamily: t.monoFamily),
            ),
            Text(
              '包名：${info.packageName}',
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.telemetry,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '签名 SHA-256：',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              info.signatureSha256,
              style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.micro),
            ),
            const SizedBox(height: 8),
            // P1-7：指纹不说明「与什么比对」= 白列——补比对指引。
            // P1-8：补「拒绝」的后果——用户需知悉不信任时会发生什么、之后
            // 如何改主意（历史病：只说了信任的后果）。
            const Text(
              '请与插件发布方（官网/应用页）公布的指纹比对，一致才可信任。\n'
              '信任 = 该插件的工具可在任务中被调用；拒绝 = 本次不挂载'
              '（其工具不可用），之后想用了可在设置页 → 本地插件面板重新信任。',
            ),
          ],
        ),
      ),
      actions: [
        // P1-8：权重修正——信任（授权第三方）弱化为 OutlinedButton；拒绝
        // （安全默认）上主位 FilledButton。主位在右，与全仓确认弹卡
        // （取消/删除）的主操作位序一致。
        OutlinedButton(onPressed: onConfirm, child: const Text('信任并挂载')),
        FilledButton(onPressed: onDeny, child: const Text('拒绝')),
      ],
    );
  }
}

/// 弹出信任卡片；用户点「信任并挂载」后持久化入白名单并返回 true，
/// 否则（拒绝/关闭）返回 false。等价原 chat_page._showTrustCard。
///
/// `barrierDismissible: false` 是**有意设计**（P1-8 核对后保留）：安全裁决
/// 必须显式——点外部关闭 = 误触，不等于默拒也不等于默准（同跨源授权卡
/// `consentDelegate` 口径）。「拒绝」按钮即安全退出路径，其后果在卡内明示。
Future<bool> showTrustCard(BuildContext context, LocalPluginInfo info) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => TrustPluginDialog(
      info: info,
      onConfirm: () => Navigator.pop(ctx, true),
      onDeny: () => Navigator.pop(ctx, false),
    ),
  );
  if (result == true) {
    final trusted = await TrustedPlugins.instance;
    await trusted.add(info.packageName, info.signatureSha256, info.serverTitle);
  }
  return result == true;
}
