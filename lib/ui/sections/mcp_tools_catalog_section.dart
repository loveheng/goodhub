/// 资源中心 · MCP 工具目录段（mcp-tools-catalog，2026-10-21）：按服务分组展示已注册
/// MCP 服务的工具，含三态可见性（共享/私有/未声明），公共靠前私有靠后（MC1~MC4）。
///
/// **取数（§8.1 注入位范式）**：经 [McpCatalog] 收口，段不持领域单例；包变更广播
/// 订阅热刷新。纯浏览面，拉完即释放连接（catalog 内 release，不常驻 face）。
/// **排序（MC2 两层都排）**：服务组按「含 shared 工具数」降序；组内工具 shared→
/// private→未声明。**分组（MC4）**：按服务分组，「远程/私有」仅是来源标注、非维度。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../coordinator/tool_catalog.dart';
import '../../core/tool_visibility.dart';
import '../tokens/console_tokens.dart';

/// 单服务工具加载态（loading / done / error 三态，单服务独立降级不阻断其他）。
class _LoadState {
  const _LoadState._({this.loading = false, this.tools, this.error});
  factory _LoadState.loading() => const _LoadState._(loading: true);
  factory _LoadState.done(List<McpCatalogTool> t) => _LoadState._(tools: t);
  factory _LoadState.error(String e) => _LoadState._(error: e);

  final bool loading;
  final List<McpCatalogTool>? tools;
  final String? error;
}

/// 段 widget：注入 [catalog] / [changes]（包变更流）/ [onFlash] / [errorRowBuilder]。
class McpToolsCatalogSection extends StatefulWidget {
  const McpToolsCatalogSection({
    super.key,
    required this.catalog,
    required this.changes,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  final McpCatalog catalog;
  final Stream<void> changes;
  final void Function(String message) onFlash;
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key}) errorRowBuilder;

  @override
  State<McpToolsCatalogSection> createState() => _McpToolsCatalogSectionState();
}

class _McpToolsCatalogSectionState extends State<McpToolsCatalogSection>
    with AutomaticKeepAliveClientMixin {
  // TabBarView 切走再回不会重建段内领域态（加载结果/展开态）——段一律申请 keepAlive。
  @override
  bool get wantKeepAlive => true;

  var _loading = false;
  String? _loadError;
  var _services = const <McpCatalogService>[];
  var _toolsByServer = const <String, _LoadState>{};
  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    // 包变更（安装/卸载插件）→ 重扫热刷新（重试路径防重复订阅）。
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

  /// 整体刷新：重拉服务清单 → 并发拉各服务工具（单服务失败独立降级）。
  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final services = await widget.catalog.loadRegisteredServices();
      if (!mounted) return;
      setState(() {
        _services = services;
        _toolsByServer = const {};
        _loading = false;
      });
      await Future.wait(services.map(_reloadServer));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '服务清单加载失败：$e';
        _loading = false;
      });
    }
  }

  /// 单服务工具拉取（挂载→listTools→释放；失败仅降级该卡片）。
  Future<void> _reloadServer(McpCatalogService s) async {
    if (!mounted) return;
    setState(() {
      _toolsByServer = {..._toolsByServer, s.serverId: _LoadState.loading()};
    });
    try {
      final tools = await widget.catalog.loadServerTools(s);
      if (!mounted) return;
      setState(() {
        _toolsByServer = {..._toolsByServer, s.serverId: _LoadState.done(tools)};
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _toolsByServer = {..._toolsByServer, s.serverId: _LoadState.error('$e')};
      });
    }
  }

  /// 服务组排序（MC2）：含 shared 工具数降序，平手按展示名升序。
  int _sharedCount(McpCatalogService s) {
    final tools = _toolsByServer[s.serverId]?.tools;
    if (tools == null) return 0;
    return tools
        .where((t) => t.declared && t.visibility == ToolVisibility.shared)
        .length;
  }

  List<McpCatalogService> _sortedServices() {
    final list = List<McpCatalogService>.of(_services);
    list.sort((a, b) {
      final c = _sharedCount(b).compareTo(_sharedCount(a));
      return c != 0 ? c : a.label.compareTo(b.label);
    });
    return list;
  }

  /// 组内工具排序（MC2）：shared(0)→private(1)→未声明(2)，同级按名升序。
  int _toolRank(McpCatalogTool t) =>
      t.declared ? (t.visibility == ToolVisibility.shared ? 0 : 1) : 2;

  List<McpCatalogTool> _sortedTools(List<McpCatalogTool> tools) {
    final list = List<McpCatalogTool>.of(tools);
    list.sort((a, b) {
      final r = _toolRank(a).compareTo(_toolRank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });
    return list;
  }

  /// 三态可见性文案（MC3：未声明单独标，防把兜底当刻意私有）。
  String _visLabel(McpCatalogTool t) =>
      !t.declared ? '未声明' : t.visibility == ToolVisibility.shared ? '共享' : '私有';

  Color _visColor(ConsoleTokens t, McpCatalogTool tool) => !tool.declared
      ? t.l2Warn
      : tool.visibility == ToolVisibility.shared
          ? t.l1Ok
          : t.terminalMuted;

  Widget _pill(ConsoleTokens t, String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(t.cardRadius),
        ),
        child: Text(label, style: TextStyle(fontSize: Fsz.microSm, color: color)),
      );

  List<Widget> _toolRows(ConsoleTokens t, List<McpCatalogTool> tools) => [
        for (final tool in tools)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tool.name,
                          style: TextStyle(
                              fontFamily: t.monoFamily, fontSize: Fsz.telemetry)),
                      if (tool.description.isNotEmpty)
                        Text(
                          tool.description,
                          style: TextStyle(
                              fontSize: Fsz.note, color: t.terminalMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _pill(t, _visLabel(tool), _visColor(t, tool)),
              ],
            ),
          ),
      ];

  Widget _serviceCard(ConsoleTokens t, McpCatalogService s) {
    final st = _toolsByServer[s.serverId];
    final tools = st?.tools;
    final shared = tools
            ?.where((x) => x.declared && x.visibility == ToolVisibility.shared)
            .length ??
        0;
    final total = tools?.length ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(s.label,
                      style: const TextStyle(fontSize: Fsz.listPrimary)),
                ),
                _pill(t, s.sourceLabel, t.terminalMuted),
              ],
            ),
            const SizedBox(height: 4),
            Text('共享 $shared / 共 $total',
                style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
            const SizedBox(height: 6),
            if (st == null || st.loading)
              Text('加载工具…',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted))
            else if (st.error != null)
              widget.errorRowBuilder(t, st.error!, () => unawaited(_reloadServer(s)))
            else
              ..._toolRows(t, _sortedTools(tools!)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必需
    final t = consoleTokens(context);
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: widget.errorRowBuilder(t, _loadError!, () => unawaited(_reload())),
        ),
      );
    }
    if (_services.isEmpty && _loading) {
      return Center(
        child: Text('加载服务…', style: TextStyle(fontSize: Fsz.telemetry)),
      );
    }
    final services = _sortedServices();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (services.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '（暂无可展示的 MCP 服务——本地插件或远端端点尚未注册）',
              style: TextStyle(fontSize: Fsz.telemetry),
            ),
          )
        else
          for (final s in services) _serviceCard(t, s),
      ],
    );
  }
}
