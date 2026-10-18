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
    required this.onDone,
    this.bindLocked = false,
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
  final VoidCallback onDone;

  /// A5（page-beautify P3）：运行中菜单**可查看不可切换**——原一刀切
  /// guard 连只读查看都弹「需等待」（查看当前绑定零收益被禁、纯添堵）。
  /// true = 绑定/清空项置灰 + 说明行；查看信息不受影响。
  final bool bindLocked;

  /// 当前是否处于公共态（''=显式公共；null=遗留「未绑定」，2026-10-18 起
  /// 新会话一律公共起步，null 在弹层按公共显示）。公共项据此不可再点。
  bool get _isPublic => bound == null || bound!.isEmpty;

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
            if (defaultId != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '默认私有服务：${endpointName(defaultId!)}（在「设置」可改）',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                ),
              ),
            const Divider(height: 16),
            // A5：运行中锁定说明（查看可用、切换待命）。
            if (bindLocked)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('任务运行中：可查看，暂不可切换绑定',
                    style: TextStyle(fontSize: Fsz.note, color: t.l2Warn)),
              ),
            if (privEndpoints.isEmpty && localPlugins.isEmpty)
              Text('无可用私有服务（私有端点请在侧边栏 → 设置页添加）',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
            // 2026-10-18（用户拍板）：「公共」为常驻首项、单选语义、不可取消
            // ——列表恒有一项选中（消灭空选态）；绑定服务后再点一次 = 回显式
            // 公共（解除覆盖），底部「清空」行随之移除（接近性：取消动作回到
            // 对象本身）。
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('公共'),
              trailing: _isPublic ? const Icon(Icons.check, size: 18) : null,
              enabled: !bindLocked,
              onTap: _isPublic ? null : () => onBind(''),
            ),
            for (final e in privEndpoints)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(e.name),
                subtitle: Text(e.id),
                trailing: (bound != null && bound == e.id)
                    ? const Icon(Icons.check, size: 18)
                    : null,
                enabled: !bindLocked,
                // 选中项再点 = 取消回公共；未选中 = 绑定（radio 语义）。
                onTap: () => (bound != null && bound == e.id)
                    ? onClear()
                    : onBind(e.id),
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
                  enabled: !bindLocked,
                  // 选中项再点 = 取消回公共；未选中 = 绑定（radio 语义）。
                  onTap: () => (bound != null && bound == lp.serverId)
                      ? onClear()
                      : onBind(lp.serverId),
                ),
            ],
            if (bound != null &&
                bound!.isNotEmpty &&
                defaultId != null &&
                defaultId != bound)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, top: 2),
                child: Text(
                  '已为本会话覆盖默认：${endpointName(defaultId!)}',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                ),
              ),
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
