/// Composer Menu 底部弹层布局体（步 4 对账 Epic C 外提，纯视图件——零状态，
/// 数据与重渲染由调用方 StatefulBuilder + 回调驱动）。
///
/// 契约：调用方传 live 快照（bound/defaultId 等在每次 setSheet 重建时重读），
/// 交互经回调回页面（绑定写回三态契约、全局钉选写回），本文件不持状态。
library;

import 'package:flutter/material.dart';

import '../../mcp/local_plugin_discovery.dart';
import '../../mcp/server_endpoints.dart';
import '../tokens/console_tokens.dart';

class SessionContextSheetBody extends StatelessWidget {
  const SessionContextSheetBody({
    super.key,
    required this.t,
    required this.bound,
    required this.privEndpoints,
    required this.localPlugins,
    required this.defaultId,
    required this.endpointName,
    required this.onBind,
    required this.onClear,
    required this.onSetDefault,
    required this.onDone,
  });

  final ConsoleTokens t;

  /// 本会话三态绑定：null=未绑定 / ''=显式公共 / id=锁定。
  final String? bound;
  final List<ServerEndpoint> privEndpoints;
  final List<LocalPluginInfo> localPlugins;
  final String? defaultId;

  /// id → 展示名（页面端点缓存查表）。
  final String Function(String id) endpointName;

  final ValueChanged<String> onBind;
  final VoidCallback onClear;
  final Future<void> Function(bool value) onSetDefault;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本次会话上下文',
                style: TextStyle(
                    fontSize: Fsz.telemetry, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              bound != null && bound!.isNotEmpty
                  ? '已锁定：${endpointName(bound!)}（$bound）'
                  : (localPlugins.isNotEmpty
                      ? '本地插件自动挂载（${localPlugins.length}）· 未锁定私有服务'
                      : '纯公共模式（无私有域）'),
              style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
            ),
            const Divider(height: 16),
            if (privEndpoints.isEmpty && localPlugins.isEmpty)
              Text('无可用私有服务（私有端点请在侧边栏 → 设置页添加）',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
            for (final e in privEndpoints)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(e.name),
                subtitle: Text(e.id),
                trailing: (bound != null && bound == e.id)
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => onBind(e.id),
              ),
            if (localPlugins.isNotEmpty) ...[
              const Divider(height: 16),
              Text('本地私有插件（自动挂载 · 零配置）',
                  style: TextStyle(
                      fontSize: Fsz.telemetry, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('私有 · 须选定后占用单槽；未选中则对本会话隐藏',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
              for (final lp in localPlugins)
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(
                      lp.serverTitle.isEmpty ? lp.serverId : lp.serverTitle),
                  subtitle: Text(lp.packageName),
                  trailing: (bound != null && bound == lp.serverId)
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => onBind(lp.serverId),
                ),
            ],
            if (bound != null && bound!.isNotEmpty) ...[
              SwitchListTile(
                title: const Text('设为全局默认'),
                subtitle: const Text('新会话默认锁定此服务'),
                value: defaultId == bound,
                onChanged: (v) => onSetDefault(v),
              ),
              ListTile(
                leading: const Icon(Icons.public),
                title: const Text('清空（纯公共）'),
                onTap: onClear,
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onDone,
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
