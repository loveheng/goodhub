/// 设置页 · 本地插件段（window-slim P1-A 分段拆解，2026-10-17 自 settings_page
/// 迁出）：Binder 发现、信任白名单编排（信任卡/撤销确认/直改白名单）、包变更流
/// 订阅重扫热刷新、卡片渲染全部自持——settings_page 只透传注入位（测试假件）
/// 与钉选回调（默认私有服务与节点卡同键，逻辑留页面）。
///
/// 迁移语义原样保留（含测试锚点 Key）：
/// - 同签名私有生态免确认自动信任；第三方走 [showTrustCard] 确认后入白名单；
/// - 撤销信任 = 仅移出白名单不动连接池（装配期闸门，非长连接状态）；
/// - 包变更流 → 重扫热刷新（重试路径防重复订阅）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../mcp/local_plugin_discovery.dart';
import '../../mcp/trusted_plugins.dart';
import '../tokens/console_tokens.dart';
import '../trust_plugin_dialog.dart';

/// 段 widget：注入 [scan]（生产 = `localPluginDiscovery.scan`，测试传假件）、
/// [changes]（包变更流）、钉选三回调（默认私有判定/写持久，owner 在页面）、
/// [onFlash]（页面级 toast 口径）、[errorRowBuilder]（面板级错误态统一件）。
class LocalPluginsSection extends StatefulWidget {
  const LocalPluginsSection({
    super.key,
    required this.scan,
    required this.changes,
    required this.isDefaultPrivate,
    required this.onPinToggle,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  final Future<List<LocalPluginInfo>> Function() scan;
  final Stream<void> changes;

  /// 该卡片是否为当前持久默认私有服务（空 id 恒假）。
  final bool Function(String id) isDefaultPrivate;

  /// 图钉点击：isDefault=true 请求取消默认，否则请求设为默认（写持久在页面）。
  final Future<void> Function(String id, String label, bool isDefault)
      onPinToggle;

  final void Function(String message) onFlash;

  /// 面板级错误态（ux-hardening P0-3 口径：Rose 文案 + 重试入口）。
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key}) errorRowBuilder;

  @override
  State<LocalPluginsSection> createState() => _LocalPluginsSectionState();
}

class _LocalPluginsSectionState extends State<LocalPluginsSection> {
  var _plugins = const <LocalPluginInfo>[];
  var _trustedPackages = const <String>{}; // 已信任包名（同签名免确认仍显式标）
  StreamSubscription<void>? _changesSub;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 重试路径防重复订阅：先摘旧订阅再挂新（幂等）。
    _changesSub = widget.changes.listen((_) {
      if (mounted) unawaited(_reload());
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final found = await widget.scan();
      var trusted = const <String>{};
      try {
        final tp = await TrustedPlugins.instance;
        trusted = tp.all().keys.toSet();
      } on Object catch (e) {
        debugPrint('[DEGRADE] local-plugins-panel: 信任白名单读取失败按空: $e');
      }
      if (!mounted) return;
      setState(() {
        _plugins = found;
        _trustedPackages = trusted;
        _error = null;
      });
    } catch (e) {
      debugPrint('[DEGRADE] local-plugins-panel: 初始化失败: $e');
      if (mounted) setState(() => _error = '本地插件读取失败：$e');
    }
  }

  Future<void> _trustPlugin(LocalPluginInfo info) async {
    final ok = await showTrustCard(context, info);
    if (ok && mounted) {
      await _reload();
      widget.onFlash('✓ 已信任 ${info.serverTitle}');
    }
  }

  /// 撤销信任（2026-10-16 自聊天页 ⚙ 迁入——原设置弹层的真缺口，大厅只有信任）。
  ///
  /// 语义 = **仅移出白名单，不动连接池**：信任闸门是装配期校验而非长连接状态
  /// ——本机下一轮装配重新弹信任卡（`chat_page` 装配循环），PC 网关侧下一轮
  /// `_assemble` 直接跳过不再暴露（`gateway_controller`）。故撤销无需断开现有
  /// 连接，也不必触碰 ConnectionManager。
  Future<void> _untrustPlugin(LocalPluginInfo info) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销信任'),
        content: Text(
          '撤销后「${info.serverTitle}」：本机下次使用需重新确认信任；'
          'PC 远程网关将不再暴露它。当前会话已建立的连接不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤销信任'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final tp = await TrustedPlugins.instance;
      await tp.remove(info.packageName);
      await _reload();
      widget.onFlash('✓ 已撤销对 ${info.serverTitle} 的信任');
    } on Object catch (e) {
      widget.onFlash('⚠ 撤销信任失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '本地插件（同机发现）',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '发现 ${_plugins.length} 项',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetrySm,
                    color: t.terminalMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '已安装且声明 MCP_SERVER 的同机插件，零配置自动挂载；同签名私有生态免确认，'
              '第三方首次需信任确认。不进手填配置（与远端节点不同源）。'
              '图钉 = 钉选为默认私有服务（与「Server 节点」同一默认键）。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              widget.errorRowBuilder(
                t,
                _error!,
                _reload,
                key: const ValueKey('local-error'),
              )
            else ...[
              for (final p in _plugins) _item(context, t, p),
              if (_plugins.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '（暂无本地插件——安装声明 MCP_SERVER 的同机应用后自动出现）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, ConsoleTokens t, LocalPluginInfo p) {
    final trusted = p.sameSignature || _trustedPackages.contains(p.packageName);
    return Container(
      key: Key('local-plugin-${p.transportId}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Row(
        children: [
          // 已发现即接入（Binder 通道存在 = 自动挂载）；会话内是否可调用须由
          // 上下文菜单锁定私有槽位决定（私有≠免隔离）。绿色点表「已发现」。
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: t.l1Ok, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.serverTitle.isNotEmpty ? p.serverTitle : p.serverId,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${p.packageName}\n${p.transportId}',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.micro,
                    color: t.terminalMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '已挂载（自动）',
                      style: TextStyle(
                        fontSize: Fsz.microSm,
                        color: t.terminalMuted,
                      ),
                    ),
                    // 默认私有 pill（方案 A：与节点卡同款行内态）。
                    if (widget.isDefaultPrivate(p.serverId)) ...[
                      const SizedBox(width: 8),
                      _defaultPill(t),
                    ],
                    const SizedBox(width: 8),
                    if (p.sameSignature)
                      Text(
                        '私有生态 · 自动信任',
                        style: TextStyle(
                          fontSize: Fsz.microSm,
                          color: t.l1Ok,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else if (trusted) ...[
                      Text(
                        '已信任',
                        style: TextStyle(
                          fontSize: Fsz.microSm,
                          color: t.l1Ok,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      // P1-8：撤销入口补后果 tooltip（可发现性 = 看得见
                      // + 看得懂点了会怎样）。
                      Tooltip(
                        message: '撤销后下次使用需重新确认信任，PC 网关也不再暴露它',
                        child: TextButton(
                          key: Key('local-untrust-${p.transportId}'),
                          onPressed: () => _untrustPlugin(p),
                          child: const Text('撤销'),
                        ),
                      ),
                    ] else ...[
                      Text(
                        '待信任',
                        style: TextStyle(
                          fontSize: Fsz.microSm,
                          color: t.l2Warn,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        key: Key('local-trust-${p.transportId}'),
                        onPressed: () => _trustPlugin(p),
                        child: const Text('信任'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // 默认私有服务钉选（方案 A：与节点卡同款图钉；候选 = serverId 非空）。
          if (p.serverId.isNotEmpty) ...[
            _pinButton(t, p),
          ],
        ],
      ),
    );
  }

  /// 「默认私有」pill（L1 就绪语义，与「生效中 / 已信任」同款字形）。
  Widget _defaultPill(ConsoleTokens t) => Text(
        '默认私有',
        style: TextStyle(
          fontSize: Fsz.microSm,
          color: t.l1Ok,
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _pinButton(ConsoleTokens t, LocalPluginInfo p) {
    final isDefault = widget.isDefaultPrivate(p.serverId);
    return IconButton(
      key: Key('local-default-${p.transportId}'),
      tooltip: isDefault ? '取消默认私有服务' : '设为默认私有服务',
      iconSize: 18,
      onPressed: () => widget.onPinToggle(
        p.serverId,
        p.serverTitle.isNotEmpty ? p.serverTitle : p.serverId,
        isDefault,
      ),
      icon: Icon(
        isDefault ? Icons.push_pin : Icons.push_pin_outlined,
        color: isDefault ? t.l1Ok : null,
      ),
    );
  }
}
