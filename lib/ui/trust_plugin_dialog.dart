/// 本地插件信任卡片（thirdconnect §1.2.6）。
///
/// 第三方（非同签名）本地插件首次接入时弹确认卡，展示包名与签名 SHA-256 指纹；
/// 确认后持久化入白名单（[TrustedPlugins]）。抽取为独立可复用 widget，便于
/// integration_test 直接驱动真实卡片路径（原 chat_page 内联实现上移至此）。
library;

import 'package:flutter/material.dart';

import '../mcp/local_plugin_discovery.dart';
import '../mcp/trusted_plugins.dart';

/// 信任卡片 UI（纯展示 + 两个回调）。标题/包名/SHA-256/「信任并挂载」均带固定文案
/// 与 monospace 指纹，便于测试按文本断言。
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
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('信任本地插件？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('发现未与 GoodHub 同签名的本地 MCP 插件：'),
              const SizedBox(height: 8),
              Text('名称：${info.serverTitle}（${info.serverId}）',
                  style: const TextStyle(fontFamily: 'monospace')),
              Text('包名：${info.packageName}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 8),
              const Text('签名 SHA-256：',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text(info.signatureSha256,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11)),
              const SizedBox(height: 8),
              const Text(
                  '确认后该包名将被加入信任白名单（可在 ⚙ 设置中撤销）。'
                  '仅信任你确认真实的插件。'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: onDeny, child: const Text('拒绝')),
          FilledButton(onPressed: onConfirm, child: const Text('信任并挂载')),
        ],
      );
}

/// 弹出信任卡片；用户点「信任并挂载」后持久化入白名单并返回 true，
/// 否则（拒绝/关闭）返回 false。等价原 chat_page._showTrustCard。
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
